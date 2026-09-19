# SPDX-License-Identifier: AGPL-3.0-only
# This file is part of scrcpy-camera-helper.
# License: GNU AGPL v3.0 or later - <https://www.gnu.org/licenses/agpl-3.0.html>
#Requires -Version 7.0
<#
scrcpy-camera-helper.ps1
Windows 11 + PowerShell 7 + scrcpy + any WASAPI render endpoint (e.g. VB-CABLE).

Turns an Android phone into a camera and/or microphone source for OBS (or any
Windows app), driven by scrcpy:

  * Camera video appears in a borderless window titled "scrcpy OBS Camera"
    that OBS Window Capture can see. The window is parked fully rendered at the
    bottom of the Z-order (Underlay) or nearly off-screen (EdgeAnchor), so you
    capture it without watching it.
  * The phone mic is forwarded as uncompressed PCM and routed per-app into the
    Windows playback endpoint you choose (classically CABLE Input), so OBS /
    Audacity / Discord read it from the cable's capture side (CABLE Output).

Session modes (one-key switches, live restart):
    [V] Video only  - camera video, no audio at all (--no-audio)
    [B] Both        - camera video + phone mic RAW PCM, routed per-app
    [S] Sound only  - phone mic only, scrcpy runs with no window at all

Camera rotation hotkeys: [0]/[9]/[N]/[8]/[7] = 0/+90/-90/+180/-180 degrees.
scrcpy applies rotation at startup, so a rotation change restarts only the
scrcpy process; the OBS-facing window keeps the same title and constant
1920x1080 size in every orientation (scrcpy letterboxes rotated content), so
OBS keeps the same capture source and auto-reattaches.

Camera configuration ([C]) is capability-driven off the connected device:
cameras, resolutions and FPS come from "scrcpy --list-cameras/--list-camera-
sizes", and the video bitrate selector is bounded by the encoder Android will
actually use (e.g. c2.qti.avc.encoder), read from its on-device codec
capabilities. No static universal lists.

The audio picker ([E]) is a native Windows dialog with live search over all
active playback (WASAPI render) endpoints. Changing the device mid-stream
migrates the running audio without a restart when possible.

Sessions are tracked explicitly (Stopped/Starting/Running/Switching/Failed),
transitions are guarded, leftovers of crashed copies are swept at startup, and
every exit path (quit, Ctrl+C, window close, error) stops scrcpy first.

Settings persist in scrcpy-camera-helper.settings.json next to this script.
A per-app persisted audio route for scrcpy is reset on owned-session stop.

Audio path in the two audio modes (CameraAudio / AudioOnly):

    Android phone mic (RAW PCM 48 kHz / 16-bit / stereo, no lossy codec)
        -> scrcpy (UNPROCESSED mic path)
        -> <selected WASAPI render endpoint, e.g. CABLE Input (VB-CABLE)>
        -> CABLE Output (VB-CABLE capture side)
        -> OBS Audio Input Capture / Discord / Zoom / Teams / browser

Only scrcpy.exe is routed; the Windows default playback device stays put.
Routing uses Windows' own audio policy interface (Windows.Media.Internal.
AudioPolicyConfig), the same class of mechanism as the Windows Volume Mixer.

Notes:
  * In audio modes, scrcpy's local playback stays enabled - that playback is
    the Windows render stream being routed into the selected endpoint.
  * Do NOT enable "Listen to this device" for CABLE Output.
  * Do NOT monitor OBS audio back into CABLE Input, or you may double the mic.
  * If OBS Window Capture uses Capture Audio (BETA), do not ALSO add a second
    scrcpy audio capture source, and prefer CameraOnly mode if OBS capture
    misbehaves with a live render stream.

scrcpy (and its bundled ADB) are the only external application requirements.
https://github.com/Genymobile/scrcpy
#>

# Command-line interface (also reachable via scrcpy-camera-helper.cmd, which
# passes all arguments through). Examples:
#   .\scrcpy-camera-helper.ps1                          # interactive TUI
#   .\scrcpy-camera-helper.ps1 -Mode CameraOnly         # preselect a mode
#   .\scrcpy-camera-helper.ps1 -Mode AudioOnly -AutoStart
param(
    # Preselect the session mode; Combine with -AutoStart to skip the setup.
    [Parameter()]
    [ValidateSet('CameraAudio', 'CameraOnly', 'AudioOnly', 'RecordOnly')]
    [string]$Mode,

    # Preselect the camera rotation in degrees (clockwise).
    [Parameter()]
    [ValidateSet(0, 90, -90, 180, -180)]
    [Nullable[int]]$Rotation,

    # Start the session immediately with the chosen/current settings, without
    # setup prompts. Audio modes require a previously saved audio device; the
    # RecordOnly mode requires a previously saved recording target.
    [Parameter()]
    [switch]$AutoStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
#
# File map (all sections are marked with banner comments like the ones above
# and below, so "go to section" is a plain text search):
#   Configuration          - tunable constants (Const) + user settings (Cfg)
#   Settings persistence   - Load-Settings / Save-Settings (JSON round-trip)
#   C# interop             - Win32, AudioRoute, DeviceWatcher, StreamDrain,
#                            RelayHost (all in namespace ScrcpyCamHelper)
#   Discovery              - scrcpy/adb resolution, device picker
#   Audio endpoints        - WASAPI enumeration + picker + per-app routing
#   Session lifecycle      - Start/Stop-Camera, parking, state machine
#   Modes & rotation       - Set-SessionMode / Set-SessionRotation
#   Device capabilities    - cameras / sizes / fps / encoder bitrate ranges
#   Recording engine       - FFmpeg-only; servers, relays, placeholders,
#                            logical sessions, settings UI
#   TUI                    - Menu, help screen, status lines
#   Entry                  - startup, takeover, exit cleanup, Menu
#
# The script is deliberately a single file (drop-in next to scrcpy.exe) and
# carries no machine-specific data: every path is derived from $PSScriptRoot
# or %TEMP%, and every machine-bound value lives in the generated settings
# file, never in the code.
# ---------------------------------------------------------------------------

$script:Version = '1.2.0'

# ---------------------------------------------------------------------------
# Tunables (not user settings). Every timeout/port/bound lives here so no
# magic numbers are scattered through the logic. Ports are *preferred* values:
# a small scan handles collisions automatically (see Resolve-MediaPorts).
# ---------------------------------------------------------------------------
$script:Const = @{
    # OBS-facing frame defaults (Cfg.Width/Height inherit these; the persisted
    # settings file can override them)
    WindowWidth          = 1920
    WindowHeight         = 1080

    # preferred 127.0.0.1 ports (adb-forward targets, relay binds, lavfi sinks)
    VideoServerPort       = 27184
    AudioServerPort       = 27185
    VideoRelayPort        = 27284
    AudioRelayPort        = 27285
    VideoPlaceholderPort  = 27484
    AudioPlaceholderPort  = 27485
    PortScanAttempts      = 20     # how far past a preferred port to probe

    # on-device scrcpy-server identities + pushed jar name
    VideoScid             = 1
    AudioScid             = 2
    ServerJarName         = 'scrcpy-camera-helper-server.jar'

    # scrcpy's CLI parser ceiling for --video-bit-rate is Int32.MaxValue
    # (2,147,483,647 bps); a parser bound, NOT a device cap.
    ScrcpyParserMaxBps    = [long]2147483647

    # timing (milliseconds unless the name says otherwise)
    WindowWaitMs          = 20000  # scrcpy window creation deadline
    WindowPollMs          = 150
    FfplayWindowWaitMs    = 40000  # ffplay preview needs the first IDR frame
    ServerReadySec        = 25     # on-device server ps-probe deadline
    ServerPollMs          = 700
    FfmpegStartSec        = 25     # recording first-bytes deadline
    FfmpegStartPollMs     = 300
    FfmpegQuitWaitMs      = 15000  # graceful stdin 'q' wait before Kill
    FfmpegKillWaitMs      = 5000
    RouteRetryDelaysMs    = @(0, 350, 650, 1200, 2200)

    # log hygiene (rotate: keep the tail, never grow past LogMaxBytes)
    LogMaxBytes           = 2MB
    LogKeepBytes          = 512KB
}

$script:Cfg = @{
    # OBS-facing window geometry (constant by design - keeps the capture
    # source identity stable across rotations and camera resizes)
    Width          = [int]$script:Const.WindowWidth
    Height         = [int]$script:Const.WindowHeight
    WindowTitle    = 'scrcpy OBS Camera'

    # Camera capture pipeline (device-capability-driven via the [C] screen)
    CameraId       = $null      # $null = default back camera (scrcpy --camera-facing=back)
    CameraSize     = '1920x1080'
    Fps            = $null      # $null = Android default (camera.md: 30)
    BitrateBps     = 20000000   # existing default, exact bits per second (was '20M')

    # Session mode:
    #   CameraAudio = camera video + phone mic (RAW PCM) routed per-app.
    #   CameraOnly  = camera video with --no-audio (OBS-friendly; no render stream).
    #   AudioOnly   = phone mic (RAW PCM) only, no video window at all.
    Mode           = 'CameraAudio'

    # Camera rotation in degrees (clockwise, user-facing).
    # Allowed: 0, 90, -90, 180, -180. Mapped to scrcpy --orientation below.
    # 180 and -180 normalize to the same scrcpy orientation (180).
    Rotation       = 0

    AudioSource    = 'mic-unprocessed'       # Android UNPROCESSED mic path: raw signal, NO AEC/AGC/noise-reduction DSP.
                                             # (Alternatives for reference: mic, mic-voice-communication (adds AEC/AGC),
                                             #  mic-camcorder, mic-voice-recognition, output + --audio-dup for device playback.)
    AudioCodec     = 'raw'            # raw = uncompressed PCM 48 kHz / 16-bit / stereo, fed straight to WASAPI.
    RequireAudio   = $true            # Fail startup if phone-mic forwarding cannot initialize (audio modes only).
    AudioBitrate   = '128K'           # Only used when AudioCodec is opus/aac/flac; ignored for raw.

    # Selected WASAPI render (playback) endpoint that receives scrcpy audio in
    # ON mode. Persisted automatically after you pick it in the TUI.
    AudioTargetId   = $null
    AudioTargetName = $null

    ParkingMode  = 'Underlay'       # Underlay or EdgeAnchor
    AnchorPixels = 8
    ScrcpyPath   = ''               # Blank = auto-detect

    # ------------------------------------------------------------------
    # Recording (FFmpeg is the ONLY backend; there is deliberately no
    # native-scrcpy recording anywhere in this application)
    # ------------------------------------------------------------------
    FFmpegPath        = ''        # resolved exe path; empty = discover
    FFprobePath       = ''        # resolved exe path; empty = discover next to ffmpeg/PATH
    RecordTarget      = 'Off'     # Off | Video | Audio | VideoAudio
    RecordDirMode     = 'Script'  # Script | Custom
    RecordDir         = ''        # used when Custom
    RecordContainer   = 'mkv'     # mkv | mp4 (validated; webm excluded - no valid combos with our codecs)
    RecordVideoPreset = 'Copy'    # Copy | Balanced | HighQuality | StorageEfficient | Custom copy
    RecordAudioMode   = 'Copy'    # Copy | Aac | Opus | Flac | Pcm
    RecordAudioBitrateKbps = 192  # only for lossy audio codecs
    RecordVideoBitrateBps  = 0    # 0 = match camera config; set when transcoding deliberately
    RecordCustomArgs    = ''      # advanced extra output-side ffmpeg args
    RecordFps           = 0       # 0 = source fps; only used when transcoding
    RecordResolution    = ''      # '' = source size; else 'WxH'

    # Disconnect behavior:
    #   'Placeholder' (Mode 1) - keep recording; write black/silence while disconnected
    #   'Split'       (Mode 2) - finalize file; start a new physical file on reconnect
    DisconnectPolicy  = 'Placeholder'
}

# A "logical recording session" (user lifetime) contains MANY physical files
# on Mode 2's natural reconnects. It ends only on explicit Stop Recording.
# Created lazily by Start-LogicalSession (via Enter-LogicalRecordingSession).
$script:LogicalSession = $null

$script:State = @{
    ScrcpyExe     = $null
    AdbExe        = $null
    Serial        = $null
    Pid           = 0
    Hwnd          = [IntPtr]::Zero
    Started       = $null
    RouteId       = $null
    RouteName     = $null
    RouteMode     = $null
    SessionState  = 'Stopped'
    # Producer selection: 'scrcpy' = scrcpy.exe client renders/plays;
    #                    'server' = standalone scrcpy-servers feed the TCP relay
    #                    (consumed by ffplay live window and/or FFmpeg recording).
    ProducerV     = 'scrcpy'
    ProducerA     = 'scrcpy'
    FFplayPid     = 0
    FFplayHwnd    = [IntPtr]::Zero
    FFplayAudioPid = 0      # hidden ffplay that plays relay audio into the cable
    # marker-only flags set once the given standalone server is running
    VideoServerPid = $false
    AudioServerPid = $false

    # FFmpeg/session-process ownership and recording lifecycle.
    # Recording: $null when off; otherwise a structured object.
    Recording     = $null
    # ./extra spawned processes (servers/splitters/ffplay) owned by the current
    # session, killed in reverse order during teardown:
    Owned         = @()

    # Disconnect detection (watch thread updates the presence flag):
    Watcher        = $null

    # Relays owned by the current logical recording/live session.
    Relays        = @()

    # disconnected/reconnect bookkeeping
    DeviceDisconnected = $false
    AwaitingReconnect  = $false
    # Split-policy disconnects deliberately stop the live leg (its producer is
    # dead); this flag asks On-DeviceReconnected to bring it back
    ResumeLiveOnReconnect = $false

    # placeholder producers ('Placeholder' disconnect policy)
    Placeholder        = $null
    RecordNeedsAudio   = $false
}

# Supported user-facing rotations (clockwise degrees). -180 and +180 are
# mathematically identical and map onto the same scrcpy orientation.
$script:RotationOptions = @(
    [pscustomobject]@{ Degrees = 0;    Label = '0 degrees' }
    [pscustomobject]@{ Degrees = 90;   Label = '+90 degrees' }
    [pscustomobject]@{ Degrees = -90;  Label = '-90 degrees' }
    [pscustomobject]@{ Degrees = 180;  Label = '+180 degrees' }
    [pscustomobject]@{ Degrees = -180; Label = '-180 degrees' }
)

$script:LogFile      = Join-Path $PSScriptRoot 'scrcpy-camera-helper.log'
$script:FfmpegLogFile= Join-Path $PSScriptRoot 'scrcpy-camera-helper.ffmpeg.log'  # stderr of recording runs
$script:TempVbs      = Join-Path $env:TEMP 'scrcpy-camera-helper-noconsole.vbs'
$script:ConfigFile   = Join-Path $PSScriptRoot 'scrcpy-camera-helper.settings.json'

# True when the file is dot-sourced (used by automated tests / by yourself to
# import the functions without starting the TUI).
$script:IsDotSourced = ($MyInvocation.InvocationName -eq '.')

function Log {
    param([string]$Text)
    try {
        # Cheap rotation: once the log grows past LogMaxBytes, keep only its
        # last LogKeepBytes so diagnostics stay useful without unbounded growth.
        $f = Get-Item -LiteralPath $script:LogFile -ErrorAction SilentlyContinue
        if ($f -and $f.Length -gt [long]$script:Const.LogMaxBytes) {
            $keep = [int]$script:Const.LogKeepBytes
            $stream = [System.IO.File]::OpenRead($script:LogFile)
            try {
                [void]$stream.Seek(-$keep, [System.IO.SeekOrigin]::End)
                $buf = New-Object byte[] $keep
                $n = $stream.Read($buf, 0, $keep)
            }
            finally {
                $stream.Dispose()
            }
            $tail = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
            # drop the first (probably partial) line of the retained tail
            $nl = $tail.IndexOf("`n")
            if ($nl -ge 0) { $tail = $tail.Substring($nl + 1) }
            Set-Content -LiteralPath $script:LogFile `
                -Value ("--- log rotated (kept last $keep bytes) ---`n" + $tail) `
                -Encoding UTF8
        }

        Add-Content -LiteralPath $script:LogFile `
            -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Text" `
            -Encoding UTF8
    }
    catch {
        # Logging must never break the camera session.
    }
}

function Wait-ForEnter {
    # Single pause helper for every "read the result, then continue" screen,
    # so menu pacing stays consistent.
    param([string]$Message = 'Press Enter to continue')
    Read-Host $Message | Out-Null
}

# ---------------------------------------------------------------------------
# Settings persistence (audio toggle + selected endpoint survive restarts)
# ---------------------------------------------------------------------------

function Load-Settings {
    try {
        if (-not (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf)) {
            return
        }

        $s = Get-Content -LiteralPath $script:ConfigFile -Raw | ConvertFrom-Json

        # StrictMode throws on missing-key property access, so probe via PSObject.
        $props = $s.PSObject.Properties
        $modeProp = $props['Mode']
        $targetIdProp = $props['AudioTargetId']
        $targetNameProp = $props['AudioTargetName']
        $parkingProp = $props['ParkingMode']
        $rotationProp = $props['Rotation']
        $cameraIdProp = $props['CameraId']
        $cameraSizeProp = $props['CameraSize']
        $fpsProp = $props['Fps']
        $bitrateProp = $props['BitrateBps']

        if ($modeProp -and $modeProp.Value -in @('CameraAudio', 'CameraOnly', 'AudioOnly', 'RecordOnly')) {
            $script:Cfg.Mode = [string]$modeProp.Value
        }

        if ($targetIdProp -and $targetIdProp.Value) {
            $script:Cfg.AudioTargetId = [string]$targetIdProp.Value
            $script:Cfg.AudioTargetName = if ($targetNameProp) { [string]$targetNameProp.Value } else { $null }
        }

        if ($parkingProp -and $parkingProp.Value -in @('Underlay', 'EdgeAnchor')) {
            $script:Cfg.ParkingMode = [string]$parkingProp.Value
        }

        # OBS-facing frame: size must stay within sane bounds and the title
        # must stay non-empty (it is the stable identity capture software
        # attaches to).
        $wProp = $props['Width']
        if ($wProp) {
            $w = 0
            if ([int]::TryParse([string]$wProp.Value, [ref]$w) -and $w -ge 160 -and $w -le 7680) {
                $script:Cfg.Width = $w
            }
        }
        $hProp = $props['Height']
        if ($hProp) {
            $h = 0
            if ([int]::TryParse([string]$hProp.Value, [ref]$h) -and $h -ge 120 -and $h -le 4320) {
                $script:Cfg.Height = $h
            }
        }
        $titleProp = $props['WindowTitle']
        if ($titleProp -and -not [string]::IsNullOrWhiteSpace([string]$titleProp.Value)) {
            $script:Cfg.WindowTitle = [string]$titleProp.Value
        }

        # Validate persisted rotation; fall back to 0 degrees when unsupported.
        if ($rotationProp -and $null -ne $rotationProp.Value) {
            $r = 0
            if ([int]::TryParse([string]$rotationProp.Value, [ref]$r) -and
                ($r -in @($script:RotationOptions.Degrees))) {
                $script:Cfg.Rotation = $r
            }
            else {
                Log "Persisted rotation '$($rotationProp.Value)' is invalid; falling back to 0."
                $script:Cfg.Rotation = 0
            }
        }

        # Camera configuration fields (all validated; anything invalid reverts
        # to the proven defaults)
        if ($cameraIdProp -and $null -ne $cameraIdProp.Value) {
            $cid = 0
            if ([int]::TryParse([string]$cameraIdProp.Value, [ref]$cid) -and $cid -ge 0) {
                $script:Cfg.CameraId = $cid
            }
        }

        if ($cameraSizeProp -and $cameraSizeProp.Value -is [string] -and
            [string]$cameraSizeProp.Value -match '^\d{2,4}x\d{2,4}$') {
            $script:Cfg.CameraSize = [string]$cameraSizeProp.Value
        }

        if ($fpsProp -and $null -ne $fpsProp.Value) {
            $f = 0
            if ([int]::TryParse([string]$fpsProp.Value, [ref]$f) -and $f -ge 1 -and $f -le 240) {
                $script:Cfg.Fps = $f
            }
        }

        if ($bitrateProp -and $null -ne $bitrateProp.Value) {
            $b = [long]0
            if ([long]::TryParse([string]$bitrateProp.Value, [ref]$b) -and $b -ge 1 -and $b -le $script:Const.ScrcpyParserMaxBps) {
                $script:Cfg.BitrateBps = $b
            }
            else {
                Log "Persisted bitrate '$($bitrateProp.Value)' invalid; using default."
            }
        }

        # recording keys (7-fileset additions; full defaults when absent)
        $p = $props
        if ($p['FFmpegPath']    -and $p['FFmpegPath'].Value)    { $script:Cfg.FFmpegPath = [string]$p['FFmpegPath'].Value }
        if ($p['FFprobePath']   -and $p['FFprobePath'].Value)   { $script:Cfg.FFprobePath = [string]$p['FFprobePath'].Value }
        if ($p['RecordTarget']  -and $p['RecordTarget'].Value -in @('Off','Video','Audio','VideoAudio')) { $script:Cfg.RecordTarget = [string]$p['RecordTarget'].Value }
        if ($p['RecordDirMode'] -and $p['RecordDirMode'].Value -in @('Script','Custom')) { $script:Cfg.RecordDirMode = [string]$p['RecordDirMode'].Value }
        if ($p['RecordDir']     ) { $script:Cfg.RecordDir = [string]$p['RecordDir'].Value }
        if ($p['RecordContainer'] -and $p['RecordContainer'].Value -in @('mkv','mp4')) { $script:Cfg.RecordContainer = [string]$p['RecordContainer'].Value }
        if ($p['RecordVideoPreset'] -and $p['RecordVideoPreset'].Value -in @($script:RecordAvailablePresets)) { $script:Cfg.RecordVideoPreset = [string]$p['RecordVideoPreset'].Value }
        if ($p['RecordAudioMode'] -and $p['RecordAudioMode'].Value -in @('Copy','Aac','Opus','Flac','Pcm')) { $script:Cfg.RecordAudioMode = [string]$p['RecordAudioMode'].Value }
        if ($p['RecordAudioBitrateKbps']) { $v = 0; if ([int]::TryParse([string]$p['RecordAudioBitrateKbps'].Value, [ref]$v) -and $v -ge 32 -and $v -le 1024) { $script:Cfg.RecordAudioBitrateKbps = $v } }
        if ($p['RecordVideoBitrateBps']) { $v = [long]0; if ([long]::TryParse([string]$p['RecordVideoBitrateBps'].Value, [ref]$v) -and $v -ge 0 -and $v -le $script:Const.ScrcpyParserMaxBps) { $script:Cfg.RecordVideoBitrateBps = $v } }
        if ($p['RecordCustomArgs']) { $script:Cfg.RecordCustomArgs = [string]$p['RecordCustomArgs'].Value }
        if ($p['RecordFps']) { $v = 0; if ([int]::TryParse([string]$p['RecordFps'].Value, [ref]$v) -and $v -ge 0 -and $v -le 240) { $script:Cfg.RecordFps = $v } }
        if ($p['RecordResolution'] -and (($p['RecordResolution'].Value -match '^\d{2,4}x\d{2,4}$') -or ([string]::IsNullOrEmpty($p['RecordResolution'].Value)))) { $script:Cfg.RecordResolution = [string]$p['RecordResolution'].Value }
        if ($p['DisconnectPolicy'] -and $p['DisconnectPolicy'].Value -in @('Placeholder','Split')) { $script:Cfg.DisconnectPolicy = [string]$p['DisconnectPolicy'].Value }

        Log "Settings loaded from $script:ConfigFile"
    }
    catch {
        Log "Settings load failed (using defaults): $($_.Exception.Message)"
    }
}

function Save-Settings {
    try {
        [pscustomobject]@{
            Mode            = [string]$script:Cfg.Mode
            Rotation        = [int]$script:Cfg.Rotation
            AudioTargetId   = $script:Cfg.AudioTargetId
            AudioTargetName = $script:Cfg.AudioTargetName
            ParkingMode     = [string]$script:Cfg.ParkingMode
            Width           = [int]$script:Cfg.Width
            Height          = [int]$script:Cfg.Height
            WindowTitle     = [string]$script:Cfg.WindowTitle
            CameraId        = $(if ($null -ne $script:Cfg.CameraId) { [int]$script:Cfg.CameraId } else { $null })
            CameraSize      = [string]$script:Cfg.CameraSize
            Fps             = $(if ($null -ne $script:Cfg.Fps) { [int]$script:Cfg.Fps } else { $null })
            BitrateBps      = [long]$script:Cfg.BitrateBps

            # recording (FFmpeg-backed)
            FFmpegPath           = [string]$script:Cfg.FFmpegPath
            FFprobePath          = [string]$script:Cfg.FFprobePath
            RecordTarget         = [string]$script:Cfg.RecordTarget
            RecordDirMode        = [string]$script:Cfg.RecordDirMode
            RecordDir            = [string]$script:Cfg.RecordDir
            RecordContainer      = [string]$script:Cfg.RecordContainer
            RecordVideoPreset    = [string]$script:Cfg.RecordVideoPreset
            RecordAudioMode      = [string]$script:Cfg.RecordAudioMode
            RecordAudioBitrateKbps = [int]$script:Cfg.RecordAudioBitrateKbps
            RecordVideoBitrateBps  = [long]$script:Cfg.RecordVideoBitrateBps
            RecordCustomArgs     = [string]$script:Cfg.RecordCustomArgs
            RecordFps            = [int]$script:Cfg.RecordFps
            RecordResolution     = [string]$script:Cfg.RecordResolution
            DisconnectPolicy     = [string]$script:Cfg.DisconnectPolicy
        } | ConvertTo-Json | Set-Content -LiteralPath $script:ConfigFile -Encoding UTF8
    }
    catch {
        Log "Settings save failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Minimal Win32 helper
# ---------------------------------------------------------------------------

if (-not ('ScrcpyCamHelper.Win32' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace ScrcpyCamHelper
{
    public static class Win32
    {
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [DllImport("user32.dll")]
        static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

        [DllImport("user32.dll")]
        static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        static extern int GetWindowTextLengthW(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int count);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetWindowPos(
            IntPtr hWnd,
            IntPtr hWndInsertAfter,
            int X,
            int Y,
            int cx,
            int cy,
            uint flags);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool PostMessageW(
            IntPtr hWnd,
            uint msg,
            IntPtr wParam,
            IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern int GetSystemMetrics(int index);

        // ------------------------------------------------------------------
        // Emergency cleanup: when the console window is closed (X button),
        // the user logs off, or the machine shuts down, close the owned
        // scrcpy politely (WM_CLOSE), then kill it if it lingers.
        // Ctrl+C / Ctrl+Break are NOT swallowed (PowerShell's own handler
        // runs, unwinds, and the script's finally block does full cleanup).
        // ------------------------------------------------------------------

        private const uint WM_CLOSE_CONST = 0x0010;

        private delegate bool ConsoleCtrlDelegate(int ctrlType);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetConsoleCtrlHandler(ConsoleCtrlDelegate handler, bool add);

        private static ConsoleCtrlDelegate _handler;
        private static uint _ownedPid = 0;
        private static IntPtr _ownedHwnd = IntPtr.Zero;
        private static readonly System.Collections.Generic.HashSet<uint> _alsoOwned = new System.Collections.Generic.HashSet<uint>();

        public static void RegisterEmergencyCleanup(uint pid, IntPtr hwnd)
        {
            _ownedPid = pid;
            _ownedHwnd = hwnd;

            if (_handler == null)
            {
                _handler = new ConsoleCtrlDelegate(OnConsoleCtrl);
                SetConsoleCtrlHandler(_handler, true);
            }
        }

        public static void RegisterExtraOwnedPid(uint pid)
        {
            _alsoOwned.Add(pid);
        }

        public static void UnregisterExtraOwnedPid(uint pid)
        {
            _alsoOwned.Remove(pid);
        }

        public static void ClearEmergencyCleanup()
        {
            _ownedPid = 0;
            _ownedHwnd = IntPtr.Zero;
            _alsoOwned.Clear();
        }

        private static bool OnConsoleCtrl(int ctrlType)
        {
            // 2 = CTRL_CLOSE_EVENT, 5 = CTRL_LOGOFF_EVENT, 6 = CTRL_SHUTDOWN_EVENT
            if (ctrlType == 2 || ctrlType == 5 || ctrlType == 6)
            {
                try
                {
                    if (_ownedHwnd != IntPtr.Zero)
                    {
                        PostMessageW(_ownedHwnd, WM_CLOSE_CONST, IntPtr.Zero, IntPtr.Zero);
                        System.Threading.Thread.Sleep(1200);
                    }

                    if (_ownedPid != 0)
                    {
                        var p = System.Diagnostics.Process.GetProcessById((int)_ownedPid);
                        if (p != null && !p.HasExited)
                        {
                            p.Kill();
                        }
                    }

                    foreach (var extra in _alsoOwned)
                    {
                        try
                        {
                            var p = System.Diagnostics.Process.GetProcessById((int)extra);
                            if (p != null && !p.HasExited) p.Kill();
                        }
                        catch { }
                    }
                }
                catch { }
            }

            return false;   // let the default handling (terminate) proceed
        }

        public static IntPtr FindVisibleWindowForPid(uint targetPid, string exactTitle)
        {
            IntPtr found = IntPtr.Zero;

            EnumWindows(delegate (IntPtr hWnd, IntPtr lParam)
            {
                uint pid;
                GetWindowThreadProcessId(hWnd, out pid);

                if (pid != targetPid || !IsWindowVisible(hWnd))
                    return true;

                int len = GetWindowTextLengthW(hWnd);
                StringBuilder sb = new StringBuilder(Math.Max(len + 1, 2));
                GetWindowTextW(hWnd, sb, sb.Capacity);

                if (String.Equals(sb.ToString(), exactTitle, StringComparison.Ordinal))
                {
                    found = hWnd;
                    return false;
                }

                return true;
            }, IntPtr.Zero);

            return found;
        }

        public static IntPtr FindVisibleWindowByTitle(string exactTitle, out uint pid)
        {
            IntPtr found = IntPtr.Zero;
            uint foundPid = 0;

            EnumWindows(delegate (IntPtr hWnd, IntPtr lParam)
            {
                if (!IsWindowVisible(hWnd))
                    return true;

                int len = GetWindowTextLengthW(hWnd);
                StringBuilder sb = new StringBuilder(Math.Max(len + 1, 2));
                GetWindowTextW(hWnd, sb, sb.Capacity);

                if (String.Equals(sb.ToString(), exactTitle, StringComparison.Ordinal))
                {
                    found = hWnd;
                    GetWindowThreadProcessId(hWnd, out foundPid);
                    return false;
                }

                return true;
            }, IntPtr.Zero);

            pid = foundPid;
            return found;
        }
    }
}
'@
}


# ---------------------------------------------------------------------------
# Windows per-app audio routing helper
# ---------------------------------------------------------------------------

if (-not ('ScrcpyCamHelper.AudioRoute' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace ScrcpyCamHelper
{
    public static class AudioRoute
    {
        // Windows 11 21H2+ AudioPolicyConfig factory IID.
        private static readonly Guid IID_AudioPolicyConfigFactory_Win11 =
            new Guid("ab3d4648-e242-459f-b02f-541c70306324");

        // Windows 10/downlevel factory IID. Kept as a fallback.
        private static readonly Guid IID_AudioPolicyConfigFactory_Downlevel =
            new Guid("2a59116d-6c4f-45e0-a74f-707e3fef9258");

        private const string RuntimeClass = "Windows.Media.Internal.AudioPolicyConfig";

        private const int RPC_E_CHANGED_MODE = unchecked((int)0x80010106);
        private const uint RO_INIT_MULTITHREADED = 1;

        // IUnknown (3) + IInspectable (3) + 19 methods before
        // SetPersistedDefaultAudioEndpoint = vtable slot 25.
        private const int SET_ENDPOINT_VTBL_SLOT = 25;

        [DllImport("combase.dll")]
        private static extern int RoInitialize(uint initType);

        [DllImport("combase.dll")]
        private static extern void RoUninitialize();

        [DllImport("combase.dll", CharSet = CharSet.Unicode)]
        private static extern int WindowsCreateString(
            [MarshalAs(UnmanagedType.LPWStr)] string sourceString,
            uint length,
            out IntPtr hstring);

        [DllImport("combase.dll")]
        private static extern int WindowsDeleteString(IntPtr hstring);

        [DllImport("combase.dll")]
        private static extern int RoGetActivationFactory(
            IntPtr activatableClassId,
            ref Guid iid,
            out IntPtr factory);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int SetPersistedDefaultAudioEndpointDelegate(
            IntPtr @this,
            uint processId,
            int flow,
            int role,
            IntPtr deviceId);

        private static void ThrowIfFailed(int hr, string operation)
        {
            if (hr < 0)
            {
                throw new COMException(
                    operation + " failed with HRESULT 0x" + ((uint)hr).ToString("X8"),
                    hr);
            }
        }

        private static IntPtr CreateHString(string value)
        {
            IntPtr h;
            int hr = WindowsCreateString(value, (uint)value.Length, out h);
            ThrowIfFailed(hr, "WindowsCreateString");
            return h;
        }

        private static IntPtr GetFactory(IntPtr runtimeClassHString)
        {
            IntPtr factory = IntPtr.Zero;

            Guid iid = IID_AudioPolicyConfigFactory_Win11;
            int hr = RoGetActivationFactory(runtimeClassHString, ref iid, out factory);

            if (hr < 0 || factory == IntPtr.Zero)
            {
                if (factory != IntPtr.Zero)
                {
                    Marshal.Release(factory);
                    factory = IntPtr.Zero;
                }

                iid = IID_AudioPolicyConfigFactory_Downlevel;
                hr = RoGetActivationFactory(runtimeClassHString, ref iid, out factory);
            }

            ThrowIfFailed(hr, "RoGetActivationFactory");

            if (factory == IntPtr.Zero)
            {
                throw new COMException("RoGetActivationFactory returned a null factory.");
            }

            return factory;
        }

        private static int CallSetEndpoint(
            IntPtr factory,
            uint processId,
            int flow,
            int role,
            IntPtr deviceId)
        {
            IntPtr vtable = Marshal.ReadIntPtr(factory);
            IntPtr fn = Marshal.ReadIntPtr(
                vtable,
                IntPtr.Size * SET_ENDPOINT_VTBL_SLOT);

            var call = Marshal.GetDelegateForFunctionPointer<
                SetPersistedDefaultAudioEndpointDelegate>(fn);

            return call(factory, processId, flow, role, deviceId);
        }

        private static void SetEndpointCore(uint processId, IntPtr endpoint)
        {
            if (processId == 0)
                throw new ArgumentOutOfRangeException("processId");

            bool uninitialize = false;
            IntPtr runtimeClass = IntPtr.Zero;
            IntPtr factory = IntPtr.Zero;

            try
            {
                int initHr = RoInitialize(RO_INIT_MULTITHREADED);

                // RPC_E_CHANGED_MODE only means the caller is already initialized
                // in a different apartment. WinRT activation is still usable.
                if (initHr >= 0)
                {
                    uninitialize = true;
                }
                else if (initHr != RPC_E_CHANGED_MODE)
                {
                    ThrowIfFailed(initHr, "RoInitialize");
                }

                runtimeClass = CreateHString(RuntimeClass);
                factory = GetFactory(runtimeClass);

                // EDataFlow.eRender = 0
                // ERole: eConsole = 0, eMultimedia = 1, eCommunications = 2
                for (int role = 0; role <= 2; role++)
                {
                    int hr = CallSetEndpoint(
                        factory,
                        processId,
                        0,
                        role,
                        endpoint);

                    ThrowIfFailed(
                        hr,
                        "SetPersistedDefaultAudioEndpoint(role=" + role + ")");
                }
            }
            finally
            {
                if (factory != IntPtr.Zero)
                    Marshal.Release(factory);

                if (runtimeClass != IntPtr.Zero)
                    WindowsDeleteString(runtimeClass);

                if (uninitialize)
                    RoUninitialize();
            }
        }

        public static void SetAppRenderEndpoint(uint processId, string endpointId)
        {
            if (String.IsNullOrWhiteSpace(endpointId))
                throw new ArgumentException("endpointId is empty.", "endpointId");

            IntPtr endpoint = IntPtr.Zero;

            try
            {
                endpoint = CreateHString(endpointId);
                SetEndpointCore(processId, endpoint);
            }
            finally
            {
                if (endpoint != IntPtr.Zero)
                    WindowsDeleteString(endpoint);
            }
        }

        public static void ClearAppRenderEndpoint(uint processId)
        {
            // A null HSTRING clears the persisted per-process route back to
            // the Windows default output device.
            SetEndpointCore(processId, IntPtr.Zero);
        }
    }
}
'@
}

if (-not ('ScrcpyCamHelper.RelayHost' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.Sockets;
using System.Threading;

namespace ScrcpyCamHelper
{
    // Background watcher driven by "adb track-devices": one long-lived
    // process pushes every device-list change, instead of spawning
    // "adb devices" on a polling timer. The push stream can silently wedge
    // after the device's transport is recreated (observed across adbd
    // restarts: the removal is delivered, the return is not) - so a slow
    // watchdog recycles the tracker when no event arrives for a while; each
    // fresh tracker immediately reports a full device list, restoring state.
    // Only writes scalars; never touches PowerShell state (safe on any thread).
    public sealed class DeviceWatcher : IDisposable
    {
        private readonly string _adb;
        private readonly string _serial;
        private volatile bool _stop;
        private readonly Thread _t;
        private readonly Thread _wd;
        private volatile Process _proc;
        private long _lastEventTicks;

        // no pushed event for this long -> the tracker is recycled
        private const int WatchdogSeconds = 20;

        public volatile bool Present;
        public volatile int PollCount;   // number of device-list updates processed
        public volatile string LastError;

        public DeviceWatcher(string adbPath, string serial)
        {
            _adb = adbPath;
            _serial = serial;
            Present = false;
            PollCount = 0;
            _lastEventTicks = DateTime.UtcNow.Ticks;
            _t = new Thread(Run) { IsBackground = true };
            _wd = new Thread(WatchdogLoop) { IsBackground = true };
        }

        public void Start() { _t.Start(); _wd.Start(); }

        private void WatchdogLoop()
        {
            while (!_stop)
            {
                for (int i = 0; i < 20 && !_stop; i++) Thread.Sleep(100);

                long last = Interlocked.Read(ref _lastEventTicks);
                var idle = DateTime.UtcNow.Ticks - last;
                if (idle > TimeSpan.FromSeconds(WatchdogSeconds).Ticks)
                {
                    try
                    {
                        var p = _proc;
                        if (p != null && !p.HasExited) p.Kill();   // reader EOFs, Run() re-attaches
                    }
                    catch { }
                    Interlocked.Exchange(ref _lastEventTicks, DateTime.UtcNow.Ticks);
                }
            }
        }

        private static bool ReadFull(StreamReader r, char[] buf, int n)
        {
            int got = 0;
            while (got < n)
            {
                int k = r.Read(buf, got, n - got);
                if (k <= 0) return false;
                got += k;
            }
            return true;
        }

        private void Run()
        {
            while (!_stop)
            {
                try
                {
                    var psi = new ProcessStartInfo
                    {
                        FileName = _adb,
                        Arguments = "track-devices",
                        UseShellExecute = false,
                        CreateNoWindow = true,
                        RedirectStandardOutput = true,
                        RedirectStandardError = true
                    };

                    using (var p = Process.Start(psi))
                    {
                        _proc = p;
                        var stdout = p.StandardOutput;

                        // The stream is a series of 4-hex-digit length-prefixed
                        // blocks; each block payload lists "serial\tstate" lines.
                        while (!_stop && !p.HasExited)
                        {
                            var hdr = new char[4];
                            if (!ReadFull(stdout, hdr, 4)) break;   // EOF: adb went away

                            int len;
                            if (!int.TryParse(new string(hdr),
                                    System.Globalization.NumberStyles.HexNumber,
                                    null, out len))
                            {
                                continue;   // not a header (shouldn't happen) - resync
                            }

                            var payload = new char[len];
                            if (!ReadFull(stdout, payload, len)) break;

                            // Presence is recomputed from the whole block: when
                            // the device vanishes, adb simply omits its line.
                            var found = false;
                            foreach (var rawLine in new string(payload).Split('\n'))
                            {
                                var line = rawLine.Trim('\r');
                                if (line.Length == 0) continue;
                                int tab = line.IndexOf('\t');
                                if (tab <= 0) continue;

                                var serial = line.Substring(0, tab);
                                var state = line.Substring(tab + 1);
                                if (serial.Equals(_serial, StringComparison.OrdinalIgnoreCase)
                                        && state == "device")
                                {
                                    found = true;
                                }
                            }

                            Present = found;
                            PollCount++;
                            LastError = null;
                            Interlocked.Exchange(ref _lastEventTicks, DateTime.UtcNow.Ticks);
                        }

                        _proc = null;
                    }
                }
                catch (Exception e)
                {
                    LastError = e.Message;
                }

                // The tracker died (or failed to start): the device state is
                // unknown until we re-attach; wait a moment, then retry.
                Present = false;
                for (int i = 0; i < 10 && !_stop; i++) Thread.Sleep(100);
            }
        }

        public void Dispose()
        {
            _stop = true;
            try
            {
                var p = _proc;
                if (p != null && !p.HasExited) p.Kill();   // unblocks the reader
            }
            catch { }
            try { _t.Join(1500); } catch { }
        }
    }


    // Drains a process stream into a file on a raw thread - never blocks the
    // writer when PS is busy. No PowerShell types cross the boundary.
    public sealed class StreamDrain : IDisposable
    {
        private readonly Stream _in;
        private readonly Stream _out;
        private readonly Thread _t;

        public StreamDrain(Stream input, string outPath)
        {
            _in = input;
            _out = new FileStream(outPath, FileMode.Create, FileAccess.Write, FileShare.ReadWrite);
            _t = new Thread(Run) { IsBackground = true };
        }

        public void Start() { _t.Start(); }

        private void Run()
        {
            try
            {
                var b = new byte[8192];
                while (true)
                {
                    int n = _in.Read(b, 0, b.Length);
                    if (n <= 0) break;
                    lock (_out)
                    {
                        _out.Write(b, 0, n);
                        _out.Flush();
                    }
                }
            }
            catch { }
            finally { try { _out.Flush(); } catch { } }
        }

        public void Dispose()
        {
            try { _out?.Dispose(); } catch { }
        }
    }


    // In-process TCP fan-out. One upstream reader (e.g. an adb-forwarded
    // scrcpy-server socket), N downstream local listeners share every byte.
    // When videoPreamble is set, the first IDR frame's prefix (SPS/PPS/IDR) is
    // remembered and replayed to any late-joining consumer; without that a
    // mid-stream joiner has no codec parameters at all.
    public sealed class RelayHost : IDisposable
    {
        public int ListenPort;

        private volatile bool _stop;
        private TcpListener _listener;
        private Thread _accept;
        private Thread _up;
        private readonly object _gate = new object();
        private readonly List<TcpClient> _clients = new List<TcpClient>();
        private readonly HashSet<IntPtr> _gotPreamble = new HashSet<IntPtr>();
        private byte[] _preamble;
        private string _upstreamHost;
        private int _upstreamPort;
        private bool _wantPreamble;

        // placeholder listener (ffmpeg lavfi writes into this while device is away)
        private TcpListener _placeholderListener;
        private Thread _phAccept;
        private int _placeholderPort;

        public static RelayHost Create(int listenPort, string upstreamHost, int upstreamPort, bool preamble, int placeholderListenPort)
        {
            var h = new RelayHost();
            h.ListenPort = listenPort;
            h.Start(listenPort, upstreamHost, upstreamPort, preamble, placeholderListenPort);
            return h;
        }

        public void Start(int listenPort, string upstreamHost, int upstreamPort, bool preamble)
        {
            Start(listenPort, upstreamHost, upstreamPort, preamble, 0);
        }

        public void Start(int listenPort, string upstreamHost, int upstreamPort, bool preamble, int placeholderListenPort)
        {
            ListenPort = listenPort;
            _wantPreamble = preamble;
            _stop = false;
            _upstreamHost = upstreamHost;
            _upstreamPort = upstreamPort;
            _placeholderPort = placeholderListenPort;

            _listener = new TcpListener(System.Net.IPAddress.Loopback, listenPort);
            _listener.Start();

            if (placeholderListenPort > 0)
            {
                _placeholderListener = new TcpListener(System.Net.IPAddress.Loopback, placeholderListenPort);
                _placeholderListener.Start();
                _phAccept = new Thread(PlaceholderAcceptLoop) { IsBackground = true };
                _phAccept.Start();
            }

            _accept = new Thread(AcceptLoop) { IsBackground = true };
            _accept.Start();

            _up = new Thread(UpstreamLoop) { IsBackground = true };
            _up.Start();
        }

        private readonly List<TcpClient> _dead = new List<TcpClient>();

        private void AcceptLoop()
        {
            while (!_stop)
            {
                try
                {
                    var c = _listener.AcceptTcpClient();
                    c.NoDelay = true;
                lock (_gate)
                {
                    _clients.Add(c);
                }
                // preamble replay happens inside WriteAll (serialized) instead:
                // it re-sends to any client that has not yet received the preamble.
                }
                catch { if (_stop) break; Thread.Sleep(50); }
            }
        }

        public string Status = "not started";
        public long BytesForwarded = 0;
        public int ClientCount { get { lock (_gate) { return _clients.Count; } } }

        private void UpstreamLoop()
        {
            var readBuf = new byte[65536];
            int attempt = 0;
            while (!_stop)
            {
                TcpClient up = null;
                try
                {
                    attempt++;
                    Status = "connecting attempt " + attempt;
                    // NO ReceiveTimeout here, ever: the scrcpy-server abstract
                    // socket admits exactly ONE streaming client per server
                    // lifetime (verified on device: after the first streaming
                    // client drops, every later connect reads instant EOF).
                    // A read timeout that kills a slow-but-healthy first
                    // connection (cold camera -> first IDR can take seconds)
                    // poisons that one slot and starves this relay forever.
                    // Dead servers end the read with EOF/exception anyway, and
                    // silent-stall liveness is handled one level up by the
                    // recording health watchdog (which restarts the server).
                    up = new TcpClient { NoDelay = true };
                    up.Connect(_upstreamHost ?? "127.0.0.1", _upstreamPort);
                    var s = up.GetStream();
                    Status = "connected, capturing preamble";

                    if (_wantPreamble)
                    {
                        _preambleTail = null;
                        _preamble = CapturePreamble(s, readBuf);
                        Status = "preamble captured, bytes=" + (_preamble == null ? -1 : _preamble.Length);
                    }

                    _primaryUp = s;

                    // Forward the bytes CapturePreamble already read PAST the
                    // preamble end (start of the next NAL): dropping them would
                    // punch a hole into the first GOP for the first consumer.
                    var tail = _preambleTail;
                    _preambleTail = null;
                    if (tail != null && tail.Length > 0)
                    {
                        WriteAll(tail, tail.Length, false);
                    }

                    PumpSource(s, false);
                }
                catch { }

                try { if (up != null) up.Close(); } catch { }
                Thread.Sleep(300);    // upstream dropped (server restart?) - reconnect
            }
            Status = "stopped";
        }

        // ---- dual upstream source plumbing:
        //   real device (outbound connect loop)
        //   placeholder producer (inbound listen) - placeholder preempts while attached.
        private volatile NetworkStream _primaryUp;
        private volatile NetworkStream _placeholderUp;
        private volatile bool _placeholderActive;
        private readonly object _srcLock = new object();

        // Bytes read past the preamble end (they belong to the first live
        // chunk's NAL); handed to the pump so no stream bytes are dropped.
        private byte[] _preambleTail;

        private byte[] CapturePreamble(NetworkStream stream, byte[] buf)
        {
            var list = new List<byte>();
            while (!_stop)
            {
                int n = stream.Read(buf, 0, buf.Length);
                if (n <= 0) throw new Exception("upstream closed during preamble");
                for (int i = 0; i < n; i++) list.Add(buf[i]);
                int end = FindFirstIdrEnd(list);
                if (end >= 0)
                {
                    _preambleTail = list.GetRange(end, list.Count - end).ToArray();
                    return list.GetRange(0, end).ToArray();
                }
                // Defensive bound: if a stream never yields an IDR end, keep no
                // more than 64MB - hand over what we have and go live anyway.
                if (list.Count > 64 * 1024 * 1024)
                {
                    _preambleTail = null;
                    return list.ToArray();
                }
            }
            return null;
        }

        private static int FindFirstIdrEnd(List<byte> data)
        {
            for (int i = 0; i + 5 <= data.Count; i++)
            {
                int sc = 0;
                if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) sc = 3;
                else if (i + 4 <= data.Count && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1) sc = 4;
                if (sc > 0 && i + sc < data.Count)
                {
                    int nalType = data[i + sc] & 0x1F;
                    if (nalType == 5)
                    {
                        for (int j = i + sc + 1; j + 5 <= data.Count; j++)
                        {
                            if (data[j] == 0 && data[j + 1] == 0 && (data[j + 2] == 1 || (data[j + 2] == 0 && data[j + 3] == 1)))
                                return j;
                        }
                        return data.Count;
                    }
                }
            }
            return -1;
        }

        // Primary reader: sets _primaryUp at connect; each typed chunk gets
        // forwarded only while no placeholder is active (or when the caller is
        // the placeholder feed itself).
        private void PumpSource(NetworkStream stream, bool isPlaceholder)
        {
            var buf = new byte[65536];
            try
            {
                while (!_stop)
                {
                    int n = stream.Read(buf, 0, buf.Length);
                    if (n <= 0) break;
                    WriteAll(buf, n, isPlaceholder);
                }
            }
            catch { }

            if (!isPlaceholder)
            {
                if (ReferenceEquals(_primaryUp, stream)) { try { _primaryUp.Close(); } catch {} _primaryUp = null; }
            }
            else
            {
                if (ReferenceEquals(_placeholderUp, stream)) { try { _placeholderUp.Close(); } catch {} _placeholderUp = null; _placeholderActive = false; }
            }
        }

        private void WriteAll(byte[] buf, int n, bool fromPlaceholder)
        {
            lock (_gate)
            {
                // placeholder, when active, owns the downstream clients
                if (fromPlaceholder != _placeholderActive) return;

                BytesForwarded += n;

                _dead.Clear();
                foreach (var c in _clients)
                {
                    try
                    {
                        var s = c.GetStream();
                        s.WriteTimeout = 5000;

                        if (_wantPreamble && _preamble != null && !_gotPreamble.Contains(c.Client.Handle))
                        {
                            s.Write(_preamble, 0, _preamble.Length);
                            _gotPreamble.Add(c.Client.Handle);
                        }

                        s.Write(buf, 0, n);
                    }
                    catch { _dead.Add(c); }
                }
                foreach (var d in _dead)
                {
                    _clients.Remove(d);
                    _gotPreamble.Remove(d.Client.Handle);
                    try { d.Close(); } catch { }
                }
            }
        }
        private void PlaceholderAcceptLoop()
        {
            while (!_stop)
            {
                try
                {
                    var c = _placeholderListener.AcceptTcpClient();
                    c.NoDelay = true;
                    var s = c.GetStream();
                    _placeholderUp = s;                        // placeholder stream registered
                    _placeholderActive = true;                 // preempts primary while present
                    PumpSource(s, true);
                }
                catch { if (_stop) break; Thread.Sleep(50); }
            }
        }

        public void Stop()
        {
            _stop = true;
            try { _listener.Stop(); } catch { }
            try { _placeholderListener?.Stop(); } catch { }
            // Close the upstream sides too, so a thread blocked in Read wakes
            // immediately instead of lingering until the far end dies.
            try { _primaryUp?.Close(); } catch { }
            try { _placeholderUp?.Close(); } catch { }
            lock (_gate)
            {
                foreach (var c in _clients.ToArray()) { try { c.Close(); } catch { } }
                _clients.Clear();
            }
        }

        // Closes every CURRENT downstream consumer socket (recorders/players see
        // a clean EOF) while the listeners stay parked for reuse by the next
        // connection. Used by the Split disconnect policy: once the on-device
        // producer is dead this relay feeds its consumers nothing, so FFmpeg's
        // stdin 'q' would strand behind its starved socket reads until it had
        // to be killed (truncated file, no duration). An EOF instead makes it
        // finalize the container (cues/duration written) and exit 0 at once.
        public void KickClients()
        {
            lock (_gate)
            {
                foreach (var c in _clients.ToArray()) { try { c.Close(); } catch { } }
                _clients.Clear();
                _gotPreamble.Clear();
            }
        }

        public void Dispose() { Stop(); }
    }
}
'@
}

$HWND_BOTTOM = [IntPtr]1
$SWP_NOACTIVATE = 0x0010
$SWP_SHOWWINDOW = 0x0040
$WM_CLOSE = 0x0010

$SM_CXSCREEN = 0
$SM_CYSCREEN = 1

function Get-PrimarySize {
    [pscustomobject]@{
        Width  = [ScrcpyCamHelper.Win32]::GetSystemMetrics($SM_CXSCREEN)
        Height = [ScrcpyCamHelper.Win32]::GetSystemMetrics($SM_CYSCREEN)
    }
}

function Get-WindowRectInfo {
    param([IntPtr]$Hwnd)

    $r = New-Object ScrcpyCamHelper.Win32+RECT

    if (-not [ScrcpyCamHelper.Win32]::GetWindowRect($Hwnd, [ref]$r)) {
        return $null
    }

    [pscustomobject]@{
        X      = $r.Left
        Y      = $r.Top
        Width  = $r.Right - $r.Left
        Height = $r.Bottom - $r.Top
    }
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

function Resolve-Scrcpy {
    $items = New-Object System.Collections.Generic.List[string]

    if ($script:Cfg.ScrcpyPath) {
        $items.Add([string]$script:Cfg.ScrcpyPath)
    }

    $items.Add((Join-Path $PSScriptRoot 'scrcpy.exe'))

    try {
        Get-ChildItem -LiteralPath $PSScriptRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'scrcpy*' } |
            ForEach-Object {
                $items.Add((Join-Path $_.FullName 'scrcpy.exe'))
            }
    }
    catch { Log "scrcpy* folder scan failed (non-fatal): $($_.Exception.Message)" }

    $cmd = @(Get-Command scrcpy.exe -CommandType Application -ErrorAction SilentlyContinue)
    if ($cmd.Count -gt 0) {
        $items.Add([string]$cmd[0].Source)
    }

    foreach ($item in ($items | Select-Object -Unique)) {
        if ($item -and (Test-Path -LiteralPath $item -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $item).Path
        }
    }

    throw @"
scrcpy.exe was not found.

Put this PS1 in your scrcpy folder, put scrcpy.exe on PATH,
or set Cfg.ScrcpyPath near the top of this file.
"@
}

function Resolve-Adb {
    param([string]$ScrcpyExe)

    $nextToScrcpy = Join-Path (Split-Path -Parent $ScrcpyExe) 'adb.exe'
    if (Test-Path -LiteralPath $nextToScrcpy -PathType Leaf) {
        return (Resolve-Path -LiteralPath $nextToScrcpy).Path
    }

    # Get-Command may return MULTIPLE matches when a tool appears more than
    # once on PATH; take the first one explicitly.
    $cmd = @(Get-Command adb.exe -CommandType Application -ErrorAction SilentlyContinue)
    if ($cmd.Count -gt 0 -and $cmd[0].Source -and (Test-Path -LiteralPath $cmd[0].Source -PathType Leaf)) {
        return [string]$cmd[0].Source
    }

    throw 'adb.exe was not found next to scrcpy.exe or on PATH.'
}

function Get-ScrcpyVersion {
    param([string]$ScrcpyExe)

    $text = & $ScrcpyExe --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "scrcpy --version failed with exit code $LASTEXITCODE."
    }

    return [string](($text | Select-Object -First 1))
}

# Lowest scrcpy version the CLI usage here relies on (camera video source and
# the modern audio flags arrived with 3.x) and the newest version the output
# parsers were validated against. Outside that window we say so instead of
# failing mysteriously deep inside a parser.
$script:ScrcpyMinVersion    = [version]'3.0'
$script:ScrcpyTestedVersion = [version]'4.1'

function Test-ScrcpyCompatibility {
    param([Parameter(Mandatory)][string]$ScrcpyExe)

    $raw = Get-ScrcpyVersion -ScrcpyExe $ScrcpyExe
    $ver = $null
    $m = [regex]::Match($raw, 'scrcpy\s+(\d+)\.(\d+)')
    if ($m.Success) {
        $ver = [version]('{0}.{1}' -f $m.Groups[1].Value, $m.Groups[2].Value)
    }

    if (-not $ver) {
        $msg = "scrcpy version string unrecognized ('$raw'); discovery parsers are validated against $($script:ScrcpyTestedVersion)."
        Log $msg
        return [pscustomobject]@{ Version = $null; Supported = $false; Message = $msg }
    }

    if ($ver -lt $script:ScrcpyMinVersion) {
        throw "scrcpy $ver is too old; this app needs $($script:ScrcpyMinVersion)+ (validated up to $($script:ScrcpyTestedVersion))."
    }

    if ($ver -gt $script:ScrcpyTestedVersion) {
        $msg = "NOTE: scrcpy $ver is newer than the validated $($script:ScrcpyTestedVersion); if discovery misbehaves, the version delta is the first suspect."
        Log $msg
        return [pscustomobject]@{ Version = $ver; Supported = $true; Message = $msg }
    }

    return [pscustomobject]@{ Version = $ver; Supported = $true; Message = $null }
}

function Get-AdbDevices {
    param([string]$AdbExe)

    $raw = & $AdbExe devices -l 2>&1
    $exit = $LASTEXITCODE

    if ($exit -ne 0) {
        throw "adb devices failed with exit code $exit.`n$($raw -join "`n")"
    }

    $devices = @()

    foreach ($lineObj in $raw) {
        $line = [string]$lineObj

        if ($line -match '^(\S+)\s+(device|unauthorized|offline)\b(.*)$') {
            $serial = $Matches[1]
            $status = $Matches[2]
            $tail = $Matches[3]
            $model = ''

            if ($tail -match '\bmodel:([^\s]+)') {
                $model = $Matches[1] -replace '_', ' '
            }

            $devices += [pscustomobject]@{
                Serial = $serial
                Status = $status
                Model  = $model
            }
        }
    }

    return $devices
}

function Choose-Device {
    param([string]$AdbExe)

    $all = @(Get-AdbDevices -AdbExe $AdbExe)
    $ready = @($all | Where-Object { $_.Status -eq 'device' })

    if ($ready.Count -eq 0) {
        if (@($all | Where-Object { $_.Status -eq 'unauthorized' }).Count -gt 0) {
            throw 'Phone found, but ADB is unauthorized. Unlock the phone and approve the USB debugging prompt.'
        }

        if (@($all | Where-Object { $_.Status -eq 'offline' }).Count -gt 0) {
            throw 'Phone is visible to ADB but is offline. Reconnect USB or restart ADB.'
        }

        throw 'No authorized Android device was found.'
    }

    if ($ready.Count -eq 1) {
        return $ready[0]
    }

    Write-Host ''
    Write-Host 'Multiple Android devices found:' -ForegroundColor Yellow

    for ($i = 0; $i -lt $ready.Count; $i++) {
        $name = if ($ready[$i].Model) { $ready[$i].Model } else { 'Unknown model' }
        Write-Host "  $($i + 1). $name [$($ready[$i].Serial)]"
    }

    Write-Host 'Type a number, then press Enter.' -ForegroundColor DarkGray

    while ($true) {
        $answer = Read-Host 'Choose device number'
        $number = 0

        if ([int]::TryParse($answer, [ref]$number)) {
            if ($number -ge 1 -and $number -le $ready.Count) {
                return $ready[$number - 1]
            }
        }
    }
}

# ---------------------------------------------------------------------------
# WASAPI render endpoint enumeration (native Windows MMDevice registry hive)
# ---------------------------------------------------------------------------

function Get-RegistryPropertyValue {
    param(
        [psobject]$Object,
        [string]$Name
    )

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop) {
        return $prop.Value
    }

    return $null
}

function Get-AudioRenderEndpoints {
    # Enumerates ACTIVE WASAPI render (playback) endpoints only.
    # Names match what Windows Sound settings shows: "<endpoint> (<device>)".
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'

    if (-not (Test-Path -LiteralPath $root)) {
        throw "Windows audio endpoint registry path not found: $root"
    }

    $descKey  = '{a45c254e-df1c-4efd-8020-67d146a850e0},2'  # PKEY_Device_DeviceDesc          e.g. "CABLE In 16ch"
    $ifaceKey = '{b3f8fa53-0004-438e-9003-51a46e139bfc},6'  # PKEY_DeviceInterface_FriendlyName e.g. "VB-Audio Virtual Cable"

    $list = New-Object System.Collections.Generic.List[object]

    foreach ($key in (Get-ChildItem -LiteralPath $root -ErrorAction Stop)) {
        $state = 0
        try {
            $itemProps = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            $rawState = Get-RegistryPropertyValue $itemProps 'DeviceState'
            if ($null -ne $rawState) {
                $state = [int]$rawState
            }
        }
        catch {
            continue
        }

        # DEVICE_STATE_ACTIVE = 0x1
        if (($state -band 0x1) -eq 0) {
            continue
        }

        $desc = $null
        $iface = $null

        try {
            $props = Get-ItemProperty -LiteralPath (Join-Path $key.PSPath 'Properties') -ErrorAction Stop
            $desc = Get-RegistryPropertyValue $props $descKey
            $iface = Get-RegistryPropertyValue $props $ifaceKey
        }
        catch { Log "audio endpoint properties unreadable for '$($key.PSChildName)' (non-fatal): $($_.Exception.Message)" }

        if (-not $desc) {
            $desc = $iface
        }

        if (-not $desc) {
            $desc = $key.PSChildName
        }

        $display = $desc
        if ($iface -and $desc -and ($iface -ne $desc)) {
            $display = "$desc ($iface)"
        }

        $list.Add([pscustomobject]@{
            Id      = '{0.0.0.00000000}.' + $key.PSChildName
            Name    = [string]$display
            State   = $state
        })
    }

    return @($list | Sort-Object Name)
}

function Get-AudioTargetPreselectIndex {
    param([object[]]$Endpoints)

    # 1. Exact match against the persisted selection.
    if ($script:Cfg.AudioTargetId) {
        for ($i = 0; $i -lt $Endpoints.Count; $i++) {
            if ($Endpoints[$i].Id -eq $script:Cfg.AudioTargetId) {
                return $i
            }
        }
    }

    # 2. VB-CABLE style render endpoint (CABLE Input / CABLE In).
    for ($i = 0; $i -lt $Endpoints.Count; $i++) {
        if ($Endpoints[$i].Name -match '(?i)cable\s*in') {
            return $i
        }
    }

    # 3. Any VB-Audio virtual device.
    for ($i = 0; $i -lt $Endpoints.Count; $i++) {
        if ($Endpoints[$i].Name -match '(?i)vb-audio|virtual cable') {
            return $i
        }
    }

    return 0
}

function Get-EndpointDisplayText {
    # Name plus a short GUID suffix so near-identical device names stay
    # distinguishable; the currently routed device is marked.
    param([Parameter(Mandatory)]$Endpoint)

    $shortId = $Endpoint.Id -replace '^\{0\.0\.0\.00000000\}\.\{', '' -replace '\}$', ''
    $shortId = $shortId.Substring(0, 8)

    $text = "$($Endpoint.Name)   [$shortId]"
    if ($Endpoint.Id -eq $script:Cfg.AudioTargetId) {
        $text += '   [current]'
    }

    return $text
}

function Try-EndpointPopup {
    # Searchable native picker. Returns:
    #   $null                    -> WinForms unavailable; caller uses console picker
    #   @{ Cancelled = $true }   -> user cancelled (Esc / Cancel / window close)
    #   @{ Cancelled = $false; Endpoint = <endpoint> } -> picked
    param(
        [object[]]$Endpoints,
        [int]$Preselect
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'scrcpy-camera-helper - select WASAPI audio output'
        $form.Width = 660
        $form.Height = 500
        $form.StartPosition = 'CenterScreen'
        $form.TopMost = $true
        $form.MinimizeBox = $false
        $form.MaximizeBox = $false
        $form.FormBorderStyle = 'FixedDialog'

        $searchLabel = New-Object System.Windows.Forms.Label
        $searchLabel.Text = 'scrcpy audio plays INTO the picked playback device.' + [Environment]::NewLine + 'For VB-CABLE pick "CABLE Input" here ("CABLE Input 16ch" works too); OBS/Audacity then read "CABLE Output".' + [Environment]::NewLine + 'Filter: type to search, arrows to move, Enter or double-click to accept.'
        $searchLabel.Left = 12
        $searchLabel.Top = 10
        $searchLabel.Width = 630
        $searchLabel.Height = 46
        $form.Controls.Add($searchLabel)

        $searchBox = New-Object System.Windows.Forms.TextBox
        $searchBox.Left = 12
        $searchBox.Top = 58
        $searchBox.Width = 620
        $form.Controls.Add($searchBox)

        $list = New-Object System.Windows.Forms.ListBox
        $list.Left = 12
        $list.Top = 88
        $list.Width = 620
        $list.Height = 304
        $list.HorizontalScrollbar = $true
        $form.Controls.Add($list)

        $ok = New-Object System.Windows.Forms.Button
        $ok.Text = 'OK'
        $ok.DialogResult = 'OK'
        $ok.Width = 110
        $ok.Left = 400
        $ok.Top = 404
        $form.Controls.Add($ok)

        $cancel = New-Object System.Windows.Forms.Button
        $cancel.Text = 'Cancel'
        $cancel.DialogResult = 'Cancel'
        $cancel.Width = 110
        $cancel.Left = 518
        $cancel.Top = 404
        $form.Controls.Add($cancel)

        $form.AcceptButton = $ok
        $form.CancelButton = $cancel

        # Items currently shown in the list (filtered view of $Endpoints).
        $script:PopupView = @($Endpoints)

        # Guard: an unhandled exception inside a WinForms event would pop an
        # intrusive modal dialog - log quietly instead.
        $refillInner = {
            # NOTE: [string]::IndexOf(string,'OrdinalIgnoreCase') is dangerous
            # in PowerShell - overload resolution tries Int32 and throws inside
            # the WinForms event. Cast the comparison explicitly.
            $needle = $searchBox.Text
            $script:PopupView = @($Endpoints | Where-Object {
                $needle -eq '' -or
                $_.Name.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            })

            $selectedId = $null
            if ($list.SelectedIndex -ge 0 -and $script:PopupViewPrevious) {
                $pi = $script:PopupViewPreviousIndex
                if ($pi -ge 0 -and $pi -lt $script:PopupViewPrevious.Count) {
                    $selectedId = $script:PopupViewPrevious[$pi].Id
                }
            }

            $list.BeginUpdate()
            $list.Items.Clear()
            foreach ($ep in $script:PopupView) {
                [void]$list.Items.Add((Get-EndpointDisplayText $ep))
            }
            $list.EndUpdate()

            # Preserve selection across refills when possible.
            $newIndex = -1
            for ($i = 0; $i -lt $script:PopupView.Count; $i++) {
                if ($script:PopupView[$i].Id -eq $selectedId) { $newIndex = $i; break }
            }
            if ($newIndex -lt 0 -and $list.Items.Count -gt 0) { $newIndex = 0 }
            $list.SelectedIndex = $newIndex

            $script:PopupViewPrevious = $script:PopupView
        }

        $refill = { try { & $refillInner } catch { Log "Popup filter error: $($_.Exception.Message)" } }

        $script:PopupViewPrevious = @($Endpoints)
        $script:PopupViewPreviousIndex = $Preselect

        $list.add_SelectedIndexChanged({
            $script:PopupViewPreviousIndex = $list.SelectedIndex
        })

        $searchBox.add_TextChanged($refill)

        $searchBox.add_KeyDown({
            param($sender, $e)
            if ($e.KeyCode -eq 'Down') {
                if ($list.Items.Count -gt 0) {
                    $list.SelectedIndex = [Math]::Min($list.SelectedIndex + 1, $list.Items.Count - 1)
                }
                $e.Handled = $true
                $e.SuppressKeyPress = $true
            }
            elseif ($e.KeyCode -eq 'Up') {
                if ($list.Items.Count -gt 0) {
                    $list.SelectedIndex = [Math]::Max($list.SelectedIndex - 1, 0)
                }
                $e.Handled = $true
                $e.SuppressKeyPress = $true
            }
        })

        $list.add_DoubleClick({ $form.DialogResult = 'OK'; $form.Close() })

        # populate once
        foreach ($ep in $script:PopupView) {
            [void]$list.Items.Add((Get-EndpointDisplayText $ep))
        }
        if ($Preselect -ge 0 -and $Preselect -lt $list.Items.Count) {
            $list.SelectedIndex = $Preselect
        }

        $form.Add_Shown({ $searchBox.Focus() })

        $result = $form.ShowDialog()

        $picked = $null
        if ($result -eq 'OK') {
            $idx = $list.SelectedIndex
            if ($idx -ge 0 -and $idx -lt $script:PopupView.Count) {
                $picked = $script:PopupView[$idx]
            }
        }

        $script:PopupView = $null
        $script:PopupViewPrevious = $null
        $script:PopupViewPreviousIndex = -1

        if ($picked) {
            return @{ Cancelled = $false; Endpoint = $picked }
        }

        return @{ Cancelled = $true }
    }
    catch {
        Log "Endpoint popup unavailable, using console picker: $($_.Exception.Message)"
        $script:PopupView = $null
        $script:PopupViewPrevious = $null
        return $null
    }
}

function Show-EndpointConsolePicker {
    param(
        [object[]]$Endpoints,
        [int]$Preselect
    )

    Write-Host ''
    Write-Host 'Active WASAPI render (playback) devices:' -ForegroundColor Yellow

    for ($i = 0; $i -lt $Endpoints.Count; $i++) {
        $text = Get-EndpointDisplayText $Endpoints[$i]
        $marker = if ($i -eq $Preselect) { ' *' } else { '' }
        Write-Host "  $($i + 1). $text$marker"
    }

    Write-Host ''
    Write-Host '* = suggested, [current] = in use.' -ForegroundColor DarkGray
    Write-Host 'Type a number (or part of a name), then press Enter. Blank Enter = suggested; 0 = cancel.' -ForegroundColor DarkGray

    while ($true) {
        $answer = (Read-Host "Device number [default $($Preselect + 1)]").Trim()

        if ($answer -eq '') {
            return $Preselect
        }

        if ($answer -eq '0') {
            return -1
        }

        $number = 0
        if ([int]::TryParse($answer, [ref]$number)) {
            if ($number -ge 1 -and $number -le $Endpoints.Count) {
                return $number - 1
            }
        }

        # Bonus: partial-name search in the console fallback too.
        $hits = @()
        for ($i = 0; $i -lt $Endpoints.Count; $i++) {
            if ($Endpoints[$i].Name.IndexOf($answer, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $hits += $i
            }
        }
        if ($hits.Count -eq 1) {
            return $hits[0]
        }
        if ($hits.Count -gt 1) {
            Write-Host "  matches: $($hits | ForEach-Object { $Endpoints[$_].Name })" -ForegroundColor DarkGray
        }
    }
}

function Select-AudioTarget {
    # Interactive WASAPI endpoint selection with persistence.
    # Returns the chosen endpoint object, or $null when the user cancelled.

    $endpoints = @(Get-AudioRenderEndpoints)

    if ($endpoints.Count -eq 0) {
        throw @"
No active WASAPI render endpoints were found.

Check Windows Sound settings. If you intended to use VB-CABLE, make sure it is
installed and its playback device ("CABLE Input" / "CABLE In 16ch") is enabled.
"@
    }

    $pre = Get-AudioTargetPreselectIndex -Endpoints $endpoints

    $picked = $null
    $popup = Try-EndpointPopup -Endpoints $endpoints -Preselect $pre

    if ($null -ne $popup) {
        if ($popup.Cancelled) {
            return $null
        }
        $picked = $popup.Endpoint
    }
    else {
        $index = Show-EndpointConsolePicker -Endpoints $endpoints -Preselect $pre
        if ($index -lt 0) {
            return $null
        }
        $picked = $endpoints[$index]
    }

    $targetChanged = $picked.Id -ne $script:Cfg.AudioTargetId

    $script:Cfg.AudioTargetId = $picked.Id
    $script:Cfg.AudioTargetName = $picked.Name
    Save-Settings

    Log "Audio target selected: $($picked.Name) [$($picked.Id)]"

    # Live session: migrate the running stream to the new device without a
    # restart (Volume Mixer semantics - Windows moves the stream when the
    # persisted per-app default changes). A controlled restart is the
    # fallback only if the live migration actually fails.
    if ($targetChanged -and (Is-SessionRunning) -and (Test-ModeAudio) -and $script:State.RouteId) {
        try {
            Set-ScrcpyAudioRoute -ProcessId $script:State.Pid -EndpointId $picked.Id -EndpointName $picked.Name
            Write-Host "Live session re-routed to: $($picked.Name)" -ForegroundColor Green
        }
        catch {
            Log "Live re-route failed, restarting scrcpy: $($_.Exception.Message)"
            Write-Host 'Live migration failed; restarting scrcpy to apply...' -ForegroundColor Yellow
            Invoke-SessionRestart -Reason 'audio device change'
        }
    }

    return $picked
}

function Get-CurrentAudioTarget {
    # Returns the active endpoint matching the persisted selection, or $null
    # if none was selected yet or the stored endpoint is currently inactive.
    if (-not $script:Cfg.AudioTargetId) {
        return $null
    }

    $endpoints = @(Get-AudioRenderEndpoints)
    $match = @($endpoints | Where-Object { $_.Id -eq $script:Cfg.AudioTargetId })

    if ($match.Count -gt 0) {
        return $match[0]
    }

    Log "Stored audio endpoint is no longer active: $($script:Cfg.AudioTargetId)"
    $script:Cfg.AudioTargetId = $null
    $script:Cfg.AudioTargetName = $null
    Save-Settings

    return $null
}

# ---------------------------------------------------------------------------
# Per-app routing wrappers
# ---------------------------------------------------------------------------

function ConvertTo-SwdDevicePath {
    param([Parameter(Mandatory)][string]$EndpointId)

    # SetPersistedDefaultAudioEndpoint (Windows.Media.Internal.AudioPolicyConfig)
    # expects the SWD device-interface path, NOT the bare MMDevice endpoint ID:
    # on current Windows 11 builds a bare ID is rejected with E_INVALIDARG.
    # The trailing GUID is DEVINTERFACE_AUDIO_RENDER.
    return '\\?\SWD#MMDEVAPI#' + $EndpointId + '#{e6327cad-dcec-4949-ae8a-991e976a79d2}'
}

function Set-ScrcpyAudioRoute {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$EndpointId,
        [string]$EndpointName = ''
    )

    # NOTE: the parameter must not be named $Pid - $PID is a read-only
    # PowerShell automatic variable, so binding to it always fails.

    $devicePath = ConvertTo-SwdDevicePath $EndpointId

    # The policy API can return E_INVALIDARG while the target process has not
    # created its audio session yet, so retry briefly. scrcpy opens its SDL
    # audio stream shortly after the window appears.
    $delaysMs = @($script:Const.RouteRetryDelaysMs)
    $lastError = $null
    $applied = $false

    foreach ($delay in $delaysMs) {
        if ($delay -gt 0) {
            Start-Sleep -Milliseconds $delay
        }

        try {
            [ScrcpyCamHelper.AudioRoute]::SetAppRenderEndpoint(
                [uint32]$ProcessId,
                $devicePath
            )
            $applied = $true
        }
        catch {
            $lastError = $_
            Log "Route attempt failed (will retry if attempts remain): $($_.Exception.Message)"
        }
    }

    if (-not $applied) {
        if ($lastError) {
            throw $lastError
        }
        throw 'Audio route application failed.'
    }

    $script:State.RouteId = $EndpointId
    $script:State.RouteName = $EndpointName
    $script:State.RouteMode = 'Automatic'
    Log "scrcpy PID $ProcessId routed to render endpoint '$EndpointName' [$EndpointId]"
}

function Clear-ScrcpyAudioRoute {
    param([Parameter(Mandatory)][int]$ProcessId)

    try {
        [ScrcpyCamHelper.AudioRoute]::ClearAppRenderEndpoint([uint32]$ProcessId)
        Log "Cleared persisted per-app audio route for PID $ProcessId (back to Windows default)."
    }
    catch {
        Log "Clearing per-app audio route for PID $ProcessId failed (non-fatal): $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Hidden scrcpy launcher
# ---------------------------------------------------------------------------

function Ensure-HiddenLauncher {
    # This is functionally the same approach as scrcpy's official
    # scrcpy-noconsole.vbs, but generated automatically so the PS1 is portable.
    $vbs = @'
strCommand = """" & WScript.Arguments(0) & """"
For i = 1 To WScript.Arguments.Count - 1
    a = Replace(WScript.Arguments(i), """", """""")
    strCommand = strCommand & " """ & a & """"
Next
CreateObject("WScript.Shell").Run strCommand, 0, False
'@

    Set-Content -LiteralPath $script:TempVbs -Value $vbs -Encoding ASCII
}

function Quote-ProcessArgument {
    param([string]$Value)

    # Start-Process ultimately needs a single Windows command line.
    # This quote routine is sufficient for our paths/options, which do not
    # contain embedded quote characters.
    if ($Value -match '"') {
        throw "Unsupported quote character in argument: $Value"
    }

    return '"' + $Value + '"'
}

function Get-ScrcpyArgumentList {
    param(
        [Parameter(Mandatory)][string]$Serial,
        [ValidateSet('CameraAudio', 'CameraOnly', 'AudioOnly')]
        [string]$Mode = [string]$script:Cfg.Mode,
        [string]$TitleOverride,
        [switch]$ForceNoAudio
    )

    $withVideo = $Mode -ne 'AudioOnly'
    $withAudio = ($Mode -ne 'CameraOnly') -and -not $ForceNoAudio

    $argsList = @('--serial', $Serial)

    if ($withVideo) {
        $title = if ($TitleOverride) { $TitleOverride } else { [string]$script:Cfg.WindowTitle }

        # Camera selection: explicit --camera-id when the user picked one,
        # otherwise the historic default (first back camera) via --camera-facing.
        $cameraSelect = if ($null -ne $script:Cfg.CameraId) {
            "--camera-id=$($script:Cfg.CameraId)"
        }
        else {
            '--camera-facing=back'
        }

        $argsList += @(
            '--video-source=camera',
            $cameraSelect,
            "--camera-size=$($script:Cfg.CameraSize)",
            "--video-bit-rate=$([long]$script:Cfg.BitrateBps)",
            "--orientation=$(ConvertTo-ScrcpyOrientation ([int]$script:Cfg.Rotation))"
        )

        if ($script:Cfg.Fps) {
            $props = Get-HighSpeedModeForSize `
                -CameraId (Get-CurrentCameraId) `
                -Size ([string]$script:Cfg.CameraSize)

            if ($props -and $script:Cfg.Fps -in @($props.FpsSet)) {
                # Android requires the constrained high-speed session for these.
                $argsList += '--camera-high-speed'
            }

            $argsList += "--camera-fps=$($script:Cfg.Fps)"
        }

        $argsList += "--window-title=$title"
    }

    if ($withAudio) {
        $argsList += "--audio-source=$($script:Cfg.AudioSource)"
        $argsList += "--audio-codec=$($script:Cfg.AudioCodec)"

        # --audio-bit-rate does not apply to the RAW codec (uncompressed PCM).
        if ($script:Cfg.AudioCodec -ne 'raw') {
            $argsList += "--audio-bit-rate=$($script:Cfg.AudioBitrate)"
        }

        if ($script:Cfg.RequireAudio) {
            $argsList += '--require-audio'
        }
    }
    else {
        $argsList += '--no-audio'
    }

    if ($withVideo) {
        $argsList += @(
            '--window-borderless',
            "--window-width=$($script:Cfg.Width)",
            "--window-height=$($script:Cfg.Height)",
            '--window-x=0',
            '--window-y=0'
        )
    }
    else {
        $argsList += '--no-video'
    }

    return $argsList
}

function Close-ForeignSessionWindow {
    # Finds a visible window with our capture title that we do NOT own
    # (an orphan from a crashed TUI, or a session owned by another running
    # copy of this script), closes it politely (WM_CLOSE), waits for it to
    # disappear, and escalates to killing its process when needed.
    # Returns $true when the title is free afterwards, $false otherwise.
    $otherPid = [uint32]0
    $otherHwnd = [ScrcpyCamHelper.Win32]::FindVisibleWindowByTitle(
        [string]$script:Cfg.WindowTitle,
        [ref]$otherPid
    )

    if ($otherHwnd -eq [IntPtr]::Zero) {
        return $true
    }

    if ($script:State.Pid -and [int]$otherPid -eq [int]$script:State.Pid) {
        # It is our own live session - not foreign at all.
        return $false
    }

    Write-Host "Detected an existing '$($script:Cfg.WindowTitle)' window (PID $otherPid)." -ForegroundColor Yellow
    Write-Host 'Shutting it down safely and taking over...' -ForegroundColor Yellow
    Log "Commandeering: closing foreign window PID=$otherPid"

    [void][ScrcpyCamHelper.Win32]::PostMessageW(
        $otherHwnd, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero
    )

    $goneDeadline = (Get-Date).AddSeconds(4)
    while ((Get-Date) -lt $goneDeadline) {
        Start-Sleep -Milliseconds 150
        $otherHwnd = [ScrcpyCamHelper.Win32]::FindVisibleWindowByTitle(
            [string]$script:Cfg.WindowTitle,
            [ref]$otherPid
        )
        if ($otherHwnd -eq [IntPtr]::Zero) {
            return $true
        }
    }

    # It did not close politely - kill the owning process.
    Log "Foreign window ignored WM_CLOSE; killing PID=$otherPid"
    try {
        Stop-Process -Id ([int]$otherPid) -Force -ErrorAction SilentlyContinue
    }
    catch { Log "kill of foreign PID $otherPid reported an error: $($_.Exception.Message)" }

    $goneDeadline = (Get-Date).AddSeconds(4)
    while ((Get-Date) -lt $goneDeadline) {
        Start-Sleep -Milliseconds 150
        $otherHwnd = [ScrcpyCamHelper.Win32]::FindVisibleWindowByTitle(
            [string]$script:Cfg.WindowTitle,
            [ref]$otherPid
        )
        if ($otherHwnd -eq [IntPtr]::Zero) {
            return $true
        }
    }

    return $false
}

function Get-ForeignScrcpyProcesses {
    # scrcpy.exe processes carrying OUR session signature (camera mode with our
    # capture window title, or an audio-only session) that this TUI instance
    # does NOT currently track. This is the windowless-aware takeover view:
    # window-title probing alone can never see an AudioOnly orphan.
    $mine = if ($script:State.Pid) { [int]$script:State.Pid } else { 0 }
    $titleRx = [regex]::Escape([string]$script:Cfg.WindowTitle)
    $found = New-Object System.Collections.Generic.List[int]

    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='scrcpy.exe'" -ErrorAction SilentlyContinue

        foreach ($p in $procs) {
            if (-not $p.CommandLine) { continue }
            if ($mine -and [int]$p.ProcessId -eq $mine) { continue }

            $cl = [string]$p.CommandLine
            $isOurs =
                (($cl -match '(?i)--video-source=camera') -and ($cl -match $titleRx)) -or
                (($cl -match '(?i)--no-video') -and ($cl -match '(?i)--audio-source=') -and ($cl -match '(?i)--audio-codec='))

            if ($isOurs) {
                $found.Add([int]$p.ProcessId)
            }
        }
    }
    catch {
        Log "Foreign scrcpy scan failed (non-fatal): $($_.Exception.Message)"
    }

    return @($found)
}

function Close-ForeignScrcpySessions {
    # Take over from BOTH shapes of foreign sessions:
    #   - windowed (camera modes): graceful WM_CLOSE first via the title,
    #   - windowless (AudioOnly):  straight process kill (no window exists).
    # Throws only when something still refuses to die.
    $foreign = @(Get-ForeignScrcpyProcesses)

    if ($foreign.Count -eq 0) {
        return
    }

    Write-Host "Found existing scrcpy session(s) not owned by this TUI: PID $($foreign -join ', ')" -ForegroundColor Yellow
    Write-Host 'Shutting them down safely and taking over...' -ForegroundColor Yellow
    Log "Commandeering foreign scrcpy session(s): $($foreign -join ', ')"

    # Graceful first: if any own our capture window, close it politely.
    [void](Close-ForeignSessionWindow)

    # Some may have exited from the window close - wait briefly.
    $goneDeadline = (Get-Date).AddSeconds(3)
    do {
        $alive = @($foreign | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($alive.Count -eq 0) { return }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $goneDeadline)

    foreach ($fp in $alive) {
        Log "Killing foreign scrcpy PID=$fp"
        try { Stop-Process -Id $fp -Force -ErrorAction Stop } catch { Log "Stop-Process failed for PID ${fp}: $($_.Exception.Message)" }
    }

    # Verify. A kill call that throws silently is how 'Stop lies' bugs happen.
    $goneDeadline = (Get-Date).AddSeconds(4)
    do {
        $alive = @($foreign | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($alive.Count -eq 0) { return }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $goneDeadline)

    throw "Could not stop existing scrcpy session(s): PID $($alive -join ', '). Close them manually (e.g. taskkill /F /PID <pid>)."
}

function Start-HiddenScrcpy {
    param(
        [string]$ScrcpyExe,
        [string]$Serial
    )

    Ensure-HiddenLauncher

    # Collision handling: another running copy / orphan session - windowed OR
    # windowless - is shut down safely first; we only throw if takeover fails.
    $windowTaken = Close-ForeignSessionWindow
    if (-not $windowTaken) {
        throw "A window named '$($script:Cfg.WindowTitle)' could not be closed or taken over. Close it manually and retry."
    }

    $foreign = @(Get-ForeignScrcpyProcesses)
    if ($foreign.Count -gt 0) {
        Close-ForeignScrcpySessions
    }

    $args = Get-ScrcpyArgumentList -Serial $Serial

    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'

    $launchParts = @(
        (Quote-ProcessArgument $script:TempVbs),
        (Quote-ProcessArgument $ScrcpyExe)
    )

    foreach ($arg in $args) {
        $launchParts += (Quote-ProcessArgument ([string]$arg))
    }

    $argLine = '//nologo ' + ($launchParts -join ' ')

    Log "Launching scrcpy: $ScrcpyExe $($args -join ' ')"

    Start-Process -FilePath $wscript -ArgumentList $argLine -WindowStyle Hidden | Out-Null

    # The VBS intentionally returns immediately. Find the actual scrcpy SDL
    # window by the unique title and then read its owning PID.
    $deadline = (Get-Date).AddMilliseconds([int]$script:Const.WindowWaitMs)
    $pidFound = [uint32]0
    $hwnd = [IntPtr]::Zero

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds ([int]$script:Const.WindowPollMs)

        $pidFound = [uint32]0
        $hwnd = [ScrcpyCamHelper.Win32]::FindVisibleWindowByTitle(
            [string]$script:Cfg.WindowTitle,
            [ref]$pidFound
        )

        if ($hwnd -ne [IntPtr]::Zero -and $pidFound -gt 0) {
            try {
                $proc = Get-Process -Id $pidFound -ErrorAction Stop
                return [pscustomobject]@{
                    Process = $proc
                    Pid     = [int]$pidFound
                    Hwnd    = $hwnd
                }
            }
            catch {
                # Window appeared while process state was changing. Retry.
            }
        }
    }

    throw @"
scrcpy did not create the expected camera window within $([int]($script:Const.WindowWaitMs / 1000)) seconds.

Run this exact command manually from the scrcpy folder to see scrcpy's error:

scrcpy $($args -join ' ')
"@
}

function Start-HiddenScrcpyAudioOnly {
    param(
        [string]$ScrcpyExe,
        [string]$Serial
    )

    # Audio-only mode: scrcpy creates no video window, so the window-title
    # lookup is impossible. Start it directly with a hidden console instead
    # and capture the PID from the process object. Sweep windowless orphans
    # first - they are invisible to the title-based takeover.
    Close-ForeignScrcpySessions

    $args = Get-ScrcpyArgumentList -Serial $Serial

    $argLine = (@($args) | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join ' '

    Log "Launching scrcpy (audio-only): $ScrcpyExe $($args -join ' ')"

    $proc = Start-Process `
        -FilePath $ScrcpyExe `
        -ArgumentList $argLine `
        -WindowStyle Hidden `
        -PassThru

    Start-Sleep -Milliseconds 400

    $alive = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    if (-not $alive) {
        throw @"
scrcpy exited immediately in audio-only mode.

Run this exact command manually from the scrcpy folder to see scrcpy's error:

scrcpy $($args -join ' ')
"@
    }

    return [pscustomobject]@{
        Process = $alive
        Pid     = [int]$alive.Id
        Hwnd    = [IntPtr]::Zero
    }
}

# ---------------------------------------------------------------------------
# Parking
# ---------------------------------------------------------------------------

function Apply-Parking {
    param(
        [IntPtr]$Hwnd,
        [ValidateSet('Underlay', 'EdgeAnchor')]
        [string]$Mode
    )

    if ($Hwnd -eq [IntPtr]::Zero) {
        throw 'Cannot park a zero HWND.'
    }

    $screen = Get-PrimarySize
    $x = 0
    $y = 0

    if ($Mode -eq 'EdgeAnchor') {
        $anchor = [Math]::Max(1, [Math]::Min(64, [int]$script:Cfg.AnchorPixels))

        # Leave a small part inside the right edge so Windows still considers
        # the window at least partly on-screen.
        $x = $screen.Width - $anchor
        $y = 0
    }

    $flags = $SWP_NOACTIVATE -bor $SWP_SHOWWINDOW

    $ok = [ScrcpyCamHelper.Win32]::SetWindowPos(
        $Hwnd,
        $HWND_BOTTOM,
        [int]$x,
        [int]$y,
        [int]$script:Cfg.Width,
        [int]$script:Cfg.Height,
        [uint32]$flags
    )

    if (-not $ok) {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "SetWindowPos failed with Win32 error $err."
    }

    Log "Parking applied: $Mode at $x,$y size $($script:Cfg.Width)x$($script:Cfg.Height)"
}

# ---------------------------------------------------------------------------
# Session lifecycle
# ---------------------------------------------------------------------------

function Is-SessionRunning {
    if (-not $script:State.Pid) {
        return $false
    }

    return $null -ne (Get-Process -Id $script:State.Pid -ErrorAction SilentlyContinue)
}

function Clear-State {
    $script:State.ScrcpyExe = $null
    $script:State.AdbExe = $null
    $script:State.Serial = $null
    $script:State.Pid = 0
    $script:State.Hwnd = [IntPtr]::Zero
    $script:State.Started = $null
    $script:State.RouteId = $null
    $script:State.RouteName = $null
    $script:State.RouteMode = $null
    # ProducerV/ProducerA deliberately survive - they are the desired runtime
    # arrangement, set just before each Start-Camera.
    $script:State.FFplayPid = 0
    $script:State.FFplayHwnd = [IntPtr]::Zero
    $script:State.FFplayAudioPid = 0
    $script:State.ResumeLiveOnReconnect = $false
}

function Test-ModeAudio {
    return $script:Cfg.Mode -in @('CameraAudio', 'AudioOnly')
}

function Test-ModeVideo {
    return $script:Cfg.Mode -ne 'AudioOnly'
}

function Get-ModeStatusLabel {
    switch ([string]$script:Cfg.Mode) {
        'CameraOnly' {
            return 'Camera only (no audio)'
        }
        'AudioOnly' {
            $name = $script:Cfg.AudioTargetName
            if (-not $name) { $name = '(no output selected yet)' }
            return "Audio only (mic RAW, no camera) -> $name"
        }
        'RecordOnly' {
            return "Record only (FFmpeg file, target: $($script:Cfg.RecordTarget))"
        }
        default {
            $name = $script:Cfg.AudioTargetName
            if (-not $name) { $name = '(no output selected yet)' }
            return "Camera + mic RAW -> $name"
        }
    }
}

function Get-AudioDetailLabel {
    if ($script:Cfg.AudioCodec -eq 'raw') {
        return "$($script:Cfg.AudioSource), RAW PCM 48kHz 16-bit stereo"
    }
    return "$($script:Cfg.AudioSource), $($script:Cfg.AudioCodec), $($script:Cfg.AudioBitrate)"
}

# --- operation model: Live and Recording are two independent operations -----
# Live      = the preview/monitoring leg (a visible window and/or audible cable
#             playback), i.e. "something is running" in session terms.
# Recording = an active FFmpeg file capture.
# The main screen always states which of them is active, and each side's
# source (Camera Only / Audio Only / Camera + Audio) separately.

function Get-OperationLabel {
    $live = Is-SessionRunning
    $rec  = Test-RecordingActive
    if ($live -and $rec) { return 'Live + Recording' }
    if ($live)           { return 'Live Only' }
    if ($rec)            { return 'Recording Only' }
    return 'Stopped'
}

function Get-LiveSourceLabel {
    switch ([string]$script:Cfg.Mode) {
        'CameraOnly'  { return 'Camera Only' }
        'AudioOnly'   { return 'Audio Only' }
        'CameraAudio' { return 'Camera + Audio' }
        'RecordOnly'  { return '(no live in Record-only mode)' }
    }
}

function Get-RecordingSourceLabel {
    # while a recording runs its fixed target wins; otherwise show the plan
    $t = if ($script:State.Recording) { [string]$script:State.Recording.Target } else { [string]$script:Cfg.RecordTarget }
    switch ($t) {
        'Video'       { return 'Camera Only' }
        'Audio'       { return 'Audio Only' }
        'Video+Audio' { return 'Camera + Audio' }   # State.Recording.Target joins with '+'
        'VideoAudio'  { return 'Camera + Audio' }
        default       { return 'Off' }
    }
}

# ---------------------------------------------------------------------------
# Session state machine
# ---------------------------------------------------------------------------
# States: Stopped, Starting, Running, Switching, Failed.
# The console TUI reads input with blocking Read-Host, so user commands are
# inherently serialized - two transitions can never run concurrently. The
# guard exists so nested/automated code paths cannot double-start either.

function Set-TransitionState {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Stopped', 'Starting', 'Running', 'Switching', 'Failed', 'Disconnected')]
        [string]$NewState
    )

    $script:State.SessionState = $NewState
    Log "SessionState -> $NewState"
}

function Test-TransitionBusy {
    return $script:State.SessionState -in @('Starting', 'Switching')
}

function Assert-TransitionAllowed {
    if (Test-TransitionBusy) {
        throw "A transition is already in progress ($($script:State.SessionState)). Wait for it to finish."
    }
}

# ---------------------------------------------------------------------------
# Camera rotation
# ---------------------------------------------------------------------------

function Get-RotationLabel {
    param([int]$Degrees)
    $opt = $script:RotationOptions | Where-Object { $_.Degrees -eq $Degrees } | Select-Object -First 1
    if ($opt) { return $opt.Label }
    return "$Degrees degrees"
}

function ConvertTo-ScrcpyOrientation {
    # Map the user-facing value to a scrcpy --orientation token (0/90/180/270).
    # Throws on unsupported values so nothing malformed ever reaches scrcpy.
    param([Parameter(Mandatory)][int]$Degrees)

    switch ($Degrees) {
        0    { return '0' }
        90   { return '90' }
        -90  { return '270' }
        180  { return '180' }
        -180 { return '180' }   # mathematically identical to +180
        default {
            throw "Unsupported rotation $Degrees degrees. Allowed: 0, +90, -90, +180, -180."
        }
    }
}

function Read-RotationChoice {
    # Returns the requested rotation in degrees, or $null when the user keeps
    # the current value / cancels. The current value is highlighted.
    param([string]$Title = 'Camera rotation')

    Write-Host ''
    Write-Host "$Title`:" -ForegroundColor Yellow

    for ($i = 0; $i -lt $script:RotationOptions.Count; $i++) {
        $opt = $script:RotationOptions[$i]
        $current = $opt.Degrees -eq [int]$script:Cfg.Rotation
        if ($current) {
            Write-Host "  [$($i + 1)] $($opt.Label)   <== current" -ForegroundColor Green
        }
        else {
            Write-Host "  [$($i + 1)] $($opt.Label)"
        }
    }

    Write-Host ''
    Write-Host 'Type a number (or degrees like 90), then press Enter. Blank Enter keeps the highlighted value.' -ForegroundColor DarkGray

    while ($true) {
        $answer = (Read-Host 'Rotation').Trim()

        if ($answer -eq '') {
            return $null
        }

        $n = 0
        if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $script:RotationOptions.Count) {
            return [int]$script:RotationOptions[$n - 1].Degrees
        }

        # Also accept typing the value directly (0, 90, -90, 180, -180).
        if ([int]::TryParse($answer, [ref]$n) -and ($n -in @($script:RotationOptions.Degrees))) {
            return $n
        }

        Write-Host 'Invalid rotation. Allowed: 0, +90, -90, +180, -180.' -ForegroundColor Yellow
    }
}

function Start-Camera {
    if (Is-SessionRunning) {
        Write-Host 'The owned camera session is already running.' -ForegroundColor Yellow
        return
    }

    Clear-State

    $mode = [string]$script:Cfg.Mode
    $isRecordOnly = ($mode -eq 'RecordOnly')
    $withVideo = $mode -ne 'AudioOnly' -and -not $isRecordOnly
    $withAudio = $mode -in @('CameraAudio', 'AudioOnly')

    # Recording-only: producer servers are started via Start-Recording, not here.
    if ($isRecordOnly) { $withVideo = $false; $withAudio = $false }

    $scrcpy = Resolve-Scrcpy
    $adb = Resolve-Adb -ScrcpyExe $scrcpy
    $version = Get-ScrcpyVersion -ScrcpyExe $scrcpy
    $device = Choose-Device -AdbExe $adb

    # Warn (never block) when running against an unvalidated scrcpy version.
    $compat = Test-ScrcpyCompatibility -ScrcpyExe $scrcpy
    if ($compat.Message) {
        Write-Host $compat.Message -ForegroundColor DarkYellow
    }

    # assign machine state BEFORE producers/spawns run - they read these
    $script:State.ScrcpyExe = $scrcpy
    $script:State.AdbExe = $adb
    $script:State.Serial = $device.Serial

    $target = $null

    if ($withAudio) {
        $target = Get-CurrentAudioTarget

        if (-not $target) {
            Write-Host ''
            Write-Host 'Audio is enabled but no output device has been selected yet.' -ForegroundColor Yellow
            Write-Host 'Pick the WASAPI render device scrcpy should play into (e.g. CABLE Input).' -ForegroundColor Yellow

            $target = Select-AudioTarget

            if (-not $target) {
                throw 'Start cancelled: no audio output endpoint was selected.'
            }
        }
    }

    Write-Host ''
    Write-Host "scrcpy:   $version"
    Write-Host "Phone:    $($device.Model) [$($device.Serial)]"
    Write-Host "Mode:     $(Get-ModeStatusLabel)"

    if ($withVideo) {
        Write-Host "Rotation: $(Get-RotationLabel ([int]$script:Cfg.Rotation)) (scrcpy --orientation=$(ConvertTo-ScrcpyOrientation ([int]$script:Cfg.Rotation)))"
    }

    if ($withAudio) {
        Write-Host "Audio output target: $($target.Name)"
    }

    $useServerVideo = ($withVideo -and $script:State.ProducerV -eq 'server')
    $useServerAudio = ($withAudio -and $script:State.ProducerA -eq 'server')

    if (-not $isRecordOnly) {
    if ($useServerVideo) {
        # Producer becomes the standalone scrcpy-server feeding our relay:
        # FFmpeg records from the same bytes that any live viewer would see.
        # The live preview keeps the original OBS-facing window identity by
        # rendering the relay with ffplay into the same title/size.
        Write-Host 'Producer: standalone scrcpy-server + relay (recording-capable)...'

        $srvV = Start-StandaloneServer -Kind 'video' -AdbExe $adb -Serial $device.Serial
        # Placeholder listener is parked from birth: a recording started later
        # (G while live) reuses this relay and must be able to fill disconnect
        # gaps with black/silence regardless of start order.
        $vPort = Start-RecordRelay -ListenPort $script:VideoRelayPort -UpstreamPort $script:VideoServerPort -VideoPreamble -PlaceholderListenPort $script:VideoPlaceholderPort

        # The preview is ffplay rendering the relay. ffplay can only open its
        # window once undecodable pre-IDR data turns into frames; if it starts
        # before the relay captured the IDR preamble, its window randevouz is
        # late by tens of seconds. Wait for the relay to actually deliver.
        $preDeadline = (Get-Date).AddSeconds([int]$script:Const.ServerReadySec)
        while ((Get-Date) -lt $preDeadline) {
            $rl = @($script:State.Relays | Where-Object { $_.ListenPort -eq $vPort } | Select-Object -First 1)
            if ($rl.Count -gt 0 -and [long]$rl[0].BytesForwarded -gt 0) { break }
            Start-Sleep -Milliseconds 250
        }

        $started = Start-FfplayLiveWindow -InputUrl "tcp://127.0.0.1:$vPort"
    }
    elseif ($withVideo) {
        if ($withAudio) { Write-Host 'Starting rear camera + phone microphone...' }
        else { Write-Host 'Starting rear camera only (--no-audio, OBS-friendly)...' }

        $started = Start-HiddenScrcpy -ScrcpyExe $scrcpy -Serial $device.Serial
    }
    elseif ($useServerAudio) {
        # Standalone audio server feeds a relay; a hidden ffplay plays the relay
        # into the cable for the live leg. The live leg is then a pure consumer:
        # stopping it (Stop live) cannot starve a relay-fed recording.
        Write-Host 'Producer: standalone scrcpy-server (audio only, recording-capable)...'
        $srvA = Start-StandaloneServer -Kind 'audio' -AdbExe $adb -Serial $device.Serial
        $aPortSolo = Start-RecordRelay -ListenPort $script:AudioRelayPort -UpstreamPort $script:AudioServerPort -PlaceholderListenPort $script:AudioPlaceholderPort
        $started = Start-FfplayLiveWindow -InputUrl "tcp://127.0.0.1:$aPortSolo" -AudioOnly
        $script:State.FFplayAudioPid = [int]$started.Pid
    }
    else {
        Write-Host 'Starting phone microphone only (no video window)...'

        $started = Start-HiddenScrcpyAudioOnly -ScrcpyExe $scrcpy -Serial $device.Serial
    }
    }

    if ($isRecordOnly) {
        Write-Host 'Record-only mode: nothing is launched yet; recording starts on [G] (or automatically if a target is set).'
        $script:State.ScrcpyExe = $scrcpy
        $script:State.AdbExe = $adb
        $script:State.Serial = $device.Serial
        $script:State.Pid = 0
        $script:State.Hwnd = [IntPtr]::Zero
        $script:State.Started = Get-Date
        return
    }

    $script:State.ScrcpyExe = $scrcpy
    $script:State.AdbExe = $adb
    $script:State.Serial = $device.Serial
    $script:State.Pid = $started.Pid
    $script:State.Hwnd = $started.Hwnd
    $script:State.Started = Get-Date

    if ($useServerVideo -and $withAudio) {
        $srvA = Start-StandaloneServer -Kind 'audio' -AdbExe $adb -Serial $device.Serial
        $aPort = Start-RecordRelay -ListenPort $script:AudioRelayPort -UpstreamPort $script:AudioServerPort -PlaceholderListenPort $script:AudioPlaceholderPort
        $ffAudio = Start-FfplayLiveWindow -InputUrl "tcp://127.0.0.1:$aPort" -AudioOnly
        $script:State.FFplayAudioPid = [int]$ffAudio.Pid
        Log "audio session rendered by ffplay pid=$($ffAudio.Pid) (audio-only window stays hidden)"
        try {
            Set-ScrcpyAudioRoute -ProcessId $ffAudio.Pid -EndpointId $target.Id -EndpointName $target.Name
        }
        catch {
            Log "Automatic audio routing for ffplay failed: $($_.Exception.Message)"
        }
    }
    elseif ($withAudio) {
        try {
            Set-ScrcpyAudioRoute -ProcessId $script:State.Pid -EndpointId $target.Id -EndpointName $target.Name
        }
        catch {
            Log "Automatic audio routing failed: $($_.Exception.Message)"
            $script:State.RouteId = $target.Id
            $script:State.RouteName = $target.Name
            $script:State.RouteMode = 'Manual required'

            Write-Host ''
            Write-Host 'AUTOMATIC AUDIO ROUTING FAILED.' -ForegroundColor Yellow
            Write-Host "Windows can still route it manually: set scrcpy output to $($target.Name)." -ForegroundColor Cyan
            Write-Host 'Opening Windows Volume Mixer...' -ForegroundColor Cyan

            try {
                Start-Process 'ms-settings:apps-volume' | Out-Null
            }
            catch { Log "could not open Windows Volume Mixer: $($_.Exception.Message)" }

            Write-Host ''
            Write-Host "In Volume Mixer: Apps -> scrcpy -> Output device -> $($target.Name)" -ForegroundColor Cyan
            Write-Host 'Then return here. The camera session will remain running.' -ForegroundColor Cyan
        }
    }
    else {
        # Hygiene: a previous (possibly crashed) run may have persisted a route
        # for scrcpy.exe. Clear it so nothing points at a stale endpoint.
        Clear-ScrcpyAudioRoute -ProcessId $script:State.Pid
    }

    if ($withVideo) {
        Apply-Parking -Hwnd $script:State.Hwnd -Mode $script:Cfg.ParkingMode
    }

    Log "Session active PID=$($script:State.Pid) serial=$($script:State.Serial) mode=$($script:Cfg.Mode)"

    # From here on, even a console-window X / logoff / shutdown closes scrcpy,
    # and a background watcher keeps reconnecting/disconnect state visible.
    [ScrcpyCamHelper.Win32]::RegisterEmergencyCleanup([uint32]$script:State.Pid, $script:State.Hwnd)
    Start-DeviceWatcher

    Write-Host ''
    Write-Host 'SESSION ACTIVE' -ForegroundColor Green
    Write-Host "PID:         $($script:State.Pid)"
    Write-Host "Mode:        $(Get-ModeStatusLabel)"

    if ($withVideo) {
        Write-Host "Rotation:    $(Get-RotationLabel ([int]$script:Cfg.Rotation)) (window stays 1920x1080; scrcpy letterboxes)"
        Write-Host "Parking:     $($script:Cfg.ParkingMode)"
        Write-Host "OBS target:  $($script:Cfg.WindowTitle)"
    }

    if ($withAudio) {
        Write-Host "Phone audio: $(Get-AudioDetailLabel)"
        Write-Host "Audio route: $($script:State.RouteMode) -> $($script:State.RouteName)"
        Write-Host ''
        Write-Host 'IN OBS / CALLING APPS:' -ForegroundColor Yellow
        Write-Host 'Add an Audio Input Capture of the cable''s capture side (e.g. CABLE Output)' -ForegroundColor Cyan
        Write-Host 'only if you actually want the phone mic in the stream/call.' -ForegroundColor Cyan

        if ($withVideo) {
            Write-Host 'Keep OBS Window Capture "Capture Audio" OFF if it misbehaves with the routed stream.' -ForegroundColor Cyan
        }
        else {
            Write-Host 'No video window exists in this mode - use [B] (camera+mic) or [V] (camera only) for video.' -ForegroundColor Cyan
        }

        Write-Host 'Never monitor OBS output back into CABLE Input.' -ForegroundColor Cyan
    }
    else {
        Write-Host ''
        Write-Host 'No-audio mode: scrcpy creates no Windows audio stream at all,' -ForegroundColor Cyan
        Write-Host 'so OBS Window Capture has nothing audio-related to conflict with.' -ForegroundColor Cyan
    }
}

function Stop-Camera {
    param([switch]$Silent)

    if (-not $script:State.Pid) {
        if (-not $Silent) {
            Write-Host 'No owned session is running.'
        }
        return
    }

    $pidToStop = [int]$script:State.Pid
    $proc = Get-Process -Id $pidToStop -ErrorAction SilentlyContinue

    # Disarm the emergency hook and stop the device watcher before teardown.
    [ScrcpyCamHelper.Win32]::ClearEmergencyCleanup()
    Stop-DeviceWatcher

    if ($proc) {
        Log "Stopping owned scrcpy PID=$pidToStop"

        # Reset the persisted per-app route while the process is still alive,
        # so future unrelated scrcpy runs fall back to the Windows default.
        if ($script:State.RouteId -and $script:State.RouteMode -eq 'Automatic') {
            Clear-ScrcpyAudioRoute -ProcessId $pidToStop
        }

        if ($script:State.Hwnd -ne [IntPtr]::Zero) {
            # Camera modes: close the SDL window politely, then escalate.
            [void][ScrcpyCamHelper.Win32]::PostMessageW(
                $script:State.Hwnd,
                $WM_CLOSE,
                [IntPtr]::Zero,
                [IntPtr]::Zero
            )

            try {
                $proc.WaitForExit(3000) | Out-Null
            }
            catch { Log "WaitForExit after WM_CLOSE noted: $($_.Exception.Message)" }

            $proc = Get-Process -Id $pidToStop -ErrorAction SilentlyContinue
        }

        if ($proc) {
            # Audio-only mode has no window to close; also the fallback when
            # the windowed close did not finish in time.
            try {
                Stop-Process -Id $pidToStop -Force -ErrorAction Stop
            }
            catch {
                Log "Stop-Process threw for PID ${pidToStop}: $($_.Exception.Message)"
            }

            # Verify death; escalated taskkill as last resort.
            $deadline = (Get-Date).AddSeconds(4)
            while ((Get-Date) -lt $deadline) {
                if (-not (Get-Process -Id $pidToStop -ErrorAction SilentlyContinue)) { break }
                Start-Sleep -Milliseconds 150
            }

            if (Get-Process -Id $pidToStop -ErrorAction SilentlyContinue) {
                Log "Stop-Process did not end PID=$pidToStop; using taskkill /F"
                try {
                    & taskkill.exe /PID $pidToStop /F 2>&1 | Out-Null
                }
                catch {
                    Log "taskkill failed for PID ${pidToStop}: $($_.Exception.Message)"
                }
            }
        }
    }

    # Tear down owned media infrastructure (relay/server/player) BEFORE the
    # state reset clears the list.
    if ($script:State.Owned.Count) {
        Stop-OwnedMediaInfra
    }

    Clear-State

    $stillThere = Get-Process -Id $pidToStop -ErrorAction SilentlyContinue
    if ($stillThere) {
        Log "STOP FAILED: scrcpy PID=$pidToStop (or player PID) is still running"
        if (-not $Silent) {
            Write-Host "FAILED to stop PID $pidToStop - it is still running." -ForegroundColor Red
        }
    }
    elseif (-not $Silent) {
        Write-Host 'Session stopped.' -ForegroundColor Green
    }
}

function Stop-LiveSession {
    # Stops ONLY the live leg (preview window / cable playback). While a
    # recording is active every recorded stream is produced on-device behind a
    # localhost relay (Ensure-RecordingProducers), so the live side is just
    # ffplay consumers - closing them cannot touch the recording. The
    # operation drops from 'Live + Recording' to 'Recording Only' (the device
    # watcher, relays, servers and FFmpeg all stay up).
    if (-not (Is-SessionRunning)) {
        Write-Host 'No live session is running.'
        return
    }

    if (-not (Test-RecordingActive)) {
        Stop-Camera
        return
    }

    # Truthfulness guard: if anything the recorder reads is still produced by
    # the scrcpy.exe client, live and recording share a process and cannot
    # come apart. With the flip in Ensure-RecordingProducers this should be
    # unreachable - refuse instead of silently killing the recording's feed.
    $recTarget = [string]$script:State.Recording.Target
    $sharesVideo = ($recTarget -match 'Video') -and ($script:State.ProducerV -ne 'server')
    $sharesAudio = ($recTarget -match 'Audio') -and ($script:State.ProducerA -ne 'server')
    if ($sharesVideo -or $sharesAudio) {
        Write-Host 'Live and this recording share their producer - they cannot be stopped' -ForegroundColor Yellow
        Write-Host 'separately in the current arrangement. Use [G] Stop Recording or [2] Stop Both.' -ForegroundColor Yellow
        return
    }

    # reset the persisted per-app route before killing the player that had it
    if ($script:State.RouteId -and $script:State.RouteMode -eq 'Automatic' -and $script:State.Pid) {
        try { Clear-ScrcpyAudioRoute -ProcessId ([int]$script:State.Pid) } catch { Log "route clear at live-stop: $($_.Exception.Message)" }
    }

    $legs = @([int]$script:State.Pid, [int]$script:State.FFplayPid, [int]$script:State.FFplayAudioPid) | Where-Object { $_ -gt 0 } | Select-Object -Unique
    foreach ($legPid in $legs) {
        $p = Get-Process -Id $legPid -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        try {
            if ($legPid -eq [int]$script:State.Pid -and $script:State.Hwnd -ne [IntPtr]::Zero) {
                [void][ScrcpyCamHelper.Win32]::PostMessageW($script:State.Hwnd, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
                try { $p.WaitForExit(1500) | Out-Null } catch { Log "live leg WM_CLOSE wait: $($_.Exception.Message)" }
                $p = Get-Process -Id $legPid -ErrorAction SilentlyContinue
            }
            if ($p) { Stop-Process -Id $legPid -Force -ErrorAction SilentlyContinue }
        }
        catch { Log "stopping live leg ${legPid}: $($_.Exception.Message)" }
        try { [ScrcpyCamHelper.Win32]::UnregisterExtraOwnedPid([uint32]$legPid) } catch { Log "unregister live leg ${legPid}: $($_.Exception.Message)" }
        $script:State.Owned = @($script:State.Owned | Where-Object { $_ -ne $legPid })
    }

    # disarm the dead main PID/Hwnd, but KEEP the extra-owned set: FFmpeg and
    # the adb servers must stay registered for console-X cleanup while the
    # recording continues without a live leg.
    [ScrcpyCamHelper.Win32]::RegisterEmergencyCleanup([uint32]0, [IntPtr]::Zero)

    $script:State.Pid = 0
    $script:State.Hwnd = [IntPtr]::Zero
    $script:State.Started = $null
    $script:State.RouteId = $null
    $script:State.RouteName = $null
    $script:State.RouteMode = $null
    $script:State.FFplayPid = 0
    $script:State.FFplayHwnd = [IntPtr]::Zero
    $script:State.FFplayAudioPid = 0

    Log 'live leg stopped; recording continues (Recording Only)'
    Write-Host ''
    Write-Host 'Live stopped. The recording keeps running - status is now Recording Only.' -ForegroundColor Green
    Write-Host 'Servers/relays stay up so the file keeps writing; [G] stops the recording.' -ForegroundColor DarkGray
}

function Stop-RecordingWithCleanup {
    # Explicit Stop Recording: finalize the file, then run the one-time
    # logical-session cleanup prompts (placeholder cut / multi-file merge).
    Stop-Recording
    if ($script:LogicalSession -and $script:LogicalSession.Active) {
        Invoke-RecordingCleanupPrompts $script:LogicalSession
        $script:LogicalSession.Active = $false
    }
}

function Stop-RecordingInfraIfIdle {
    # When Stop Recording leaves NOTHING running (Recording Only -> Stopped),
    # the on-device servers, adb forwards and any placeholder feeds must not
    # keep holding the phone's camera/mic. (Relays stay parked deliberately:
    # they are in-process, reusable by the next recording, and die with the
    # app.) When a live leg survives, the servers stay too - they feed it.
    if (Is-SessionRunning)   { return }
    if (Test-RecordingActive) { return }
    try { Stop-PlaceholderStreams } catch { Log "placeholder stop at idle: $($_.Exception.Message)" }
    try { Stop-OwnedMediaInfra }    catch { Log "media infra stop at idle: $($_.Exception.Message)" }
    $script:State.VideoServerPid = $false
    $script:State.AudioServerPid = $false
    # no live leg and no recording: the disconnect watcher has nothing left to
    # protect - free its long-lived `adb track-devices` child too
    try { Stop-DeviceWatcher } catch { Log "watcher stop at idle: $($_.Exception.Message)" }
    Log 'recording stopped with no live leg: released device-side producers and watcher'
}

function Toggle-Parking {
    if ($script:Cfg.ParkingMode -eq 'Underlay') {
        $script:Cfg.ParkingMode = 'EdgeAnchor'
    }
    else {
        $script:Cfg.ParkingMode = 'Underlay'
    }

    Save-Settings

    if ((Is-SessionRunning) -and $script:State.Hwnd -ne [IntPtr]::Zero) {
        Apply-Parking -Hwnd $script:State.Hwnd -Mode $script:Cfg.ParkingMode
    }
}

function Set-SessionMode {
    # Independent hotkey target - one keystroke switches directly to the mode,
    # no cycling or intermediate picker. Rotation and the WASAPI device are
    # preserved across mode switches by design (they are configuration).
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CameraAudio', 'CameraOnly', 'AudioOnly', 'RecordOnly')]
        [string]$NewMode
    )

    Assert-TransitionAllowed

    # Mode switches restart/live-replace the preview leg - never silently while
    # a recording owns the producers. The recording must be stopped first.
    if (Test-RecordingActive) {
        Write-Host 'A recording is running - switching modes would interrupt it.' -ForegroundColor Yellow
        Write-Host 'Stop it first ([G] Stop Recording or [2] Stop Both).' -ForegroundColor DarkGray
        return
    }

    if ($NewMode -eq $script:Cfg.Mode) {
        if (Is-SessionRunning) {
            Write-Host "Mode unchanged: $(Get-ModeStatusLabel)" -ForegroundColor DarkGray
            return
        }

        # Stopped + picking the already-selected mode = "start with this mode".
        Write-Host "Mode: $(Get-ModeStatusLabel)" -ForegroundColor Cyan
        Invoke-StartFlow -ModeChosen
        return
    }

    $script:Cfg.Mode = [string]$NewMode
    Save-Settings
    Log "Mode switched to $NewMode"

    Write-Host ''
    Write-Host "Mode is now: $(Get-ModeStatusLabel)" -ForegroundColor Cyan

    if (Is-SessionRunning) {
        Invoke-SessionRestart -Reason "mode change to $NewMode"
    }
    else {
        Invoke-StartFlow -ModeChosen
    }
}

function Invoke-SessionRestart {
    # Controlled restart of the internal scrcpy producer. The persistent
    # external capture endpoint (the OBS-facing window title/size) is never
    # renamed, so downstream capture auto-reattaches. Rotation, mode, parking
    # and the WASAPI device are all configuration - preserved by design.
    param([string]$Reason = 'settings change')

    Assert-TransitionAllowed

    if (-not (Is-SessionRunning)) {
        Write-Host 'No session is running.' -ForegroundColor Yellow
        return
    }

    Write-Host "Restarting session ($Reason)..." -ForegroundColor Yellow
    Set-TransitionState 'Switching'

    try {
        Stop-Camera -Silent
        Start-Camera
        Set-TransitionState 'Running'
    }
    catch {
        Set-TransitionState 'Failed'
        Log "Session restart failed ($Reason): $($_.Exception.Message)"
        throw
    }
}

function Read-ModeChoice {
    # The guided start requires an EXPLICIT mode decision (or an explicit
    # cancel) - Enter alone is never taken as an answer here.
    $modes = @(
        [pscustomobject]@{ Key = 'V'; Mode = 'CameraOnly';  Label = 'Video only';   Hint = 'camera picture, no audio' }
        [pscustomobject]@{ Key = 'B'; Mode = 'CameraAudio'; Label = 'Camera + mic'; Hint = 'picture and sound' }
        [pscustomobject]@{ Key = 'S'; Mode = 'AudioOnly';   Label = 'Sound only';   Hint = 'phone mic, no window' }
        [pscustomobject]@{ Key = 'F'; Mode = 'RecordOnly';  Label = 'Record only';  Hint = 'straight to a file, nothing live' }
    )

    Write-TuiSection 'Step 1 - what should the phone be?'
    foreach ($m in $modes) {
        $mark = if ($m.Mode -eq $script:Cfg.Mode) { ' (current)' } else { '' }
        Write-TuiKey -Key $m.Key -Text ($m.Label + $mark) -Hint $m.Hint
    }
    Write-Host ''
    Write-Host '  Type a letter (or X to cancel) and press Enter.' -ForegroundColor DarkGray

    while ($true) {
        $answer = (Read-Host '  Mode (V/B/S/F)').Trim().ToUpperInvariant()
        if ($answer -eq 'X') { return $null }
        $hit = @($modes | Where-Object { $_.Key -eq $answer } | Select-Object -First 1)
        if ($hit.Count -gt 0) { return [string]$hit[0].Mode }
        Write-Host '  Pick one of V, B, S, F - or X to cancel.' -ForegroundColor Yellow
    }
}

function Read-YesNo {
    # explicit y/n with a shown default for Enter
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [bool]$Default = $false
    )
    $tag = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $a = (Read-Host ("  $Prompt [$tag]")).Trim().ToUpperInvariant()
        if ($a -eq '') { return $Default }
        if ($a -in @('Y', 'YES')) { return $true }
        if ($a -in @('N', 'NO')) { return $false }
        Write-Host '  Answer Y or N.' -ForegroundColor Yellow
    }
}

function Read-DisconnectPolicyChoice {
    # Stepped picker for the unplug-during-recording behavior. Enter keeps the
    # current policy; the wording is plain: what happens to the file when the
    # phone disappears and returns.
    Write-Host ''
    Write-Host '  If the phone disconnects while a recording runs:' -ForegroundColor Yellow
    Write-TuiKey 'P' 'Bridge the gap in the same file' 'black frames + silence, one continuous file'
    Write-TuiKey 'S' 'Split into a new file on return' 'current file finalizes cleanly, next starts fresh'
    Write-Host ("  Current: " + $(if ($script:Cfg.DisconnectPolicy -eq 'Placeholder') { 'Bridge (P)' } else { 'Split (S)' })) -ForegroundColor DarkGray

    while ($true) {
        $a = (Read-Host '  Disconnect behavior (P/S, then Enter; blank keeps current)').Trim().ToUpperInvariant()
        if ($a -eq '') { return }
        if ($a -eq 'P') { $script:Cfg.DisconnectPolicy = 'Placeholder'; Save-Settings; return }
        if ($a -eq 'S') { $script:Cfg.DisconnectPolicy = 'Split'; Save-Settings; return }
        Write-Host '  Pick P or S - or Enter to keep the current one.' -ForegroundColor Yellow
    }
}

function Read-RecordTargetChoice {    # explicit target pick used whenever recording is wanted but nothing valid
    # is saved yet - the user must be able to say out loud what gets captured
    while ($true) {
        Write-TuiKey 'V' 'Video only'
        Write-TuiKey 'A' 'Audio only'
        Write-TuiKey 'B' 'Both (video + audio)'
        Write-Host '  Type a letter, then press Enter.' -ForegroundColor DarkGray
        $a = (Read-Host '  Record what? (V/A/B)').Trim().ToUpperInvariant()
        switch ($a) {
            'V' { return 'Video' }
            'A' { return 'Audio' }
            'B' { return 'VideoAudio' }
        }
        Write-Host '  Pick V, A or B.' -ForegroundColor Yellow
    }
}

function Invoke-StartFlow {
    # The guided, step-by-step start. Every decision is explicit; nothing is
    # silently reused from a previous run without being shown. Steps:
    #   1. mode (skipped only when a mode hotkey already chose it)
    #   2. rotation            (camera modes only)
    #   3. audio output device (audio modes only)
    #   4. record too?         (live modes; implied yes for Record only)
    #   5. recording settings  (accept the shown defaults or open [K] to change)
    #   6. confirmation
    # -AutoStart skips this entire flow by design.
    param([switch]$ModeChosen)

    Assert-TransitionAllowed

    if (Is-SessionRunning) {
        Write-Host 'A session is already running. Stop it with [2], or restart it with [3].' -ForegroundColor Yellow
        return
    }

    Write-TuiHeader 'Start - guided setup'
    $stepNum = 0

    # --- step 1: session mode
    if (-not $ModeChosen) {
        $stepNum++
        $m = Read-ModeChoice
        if ($null -eq $m) { Write-Host '  Cancelled - nothing started.' -ForegroundColor DarkGray; return }
        $script:Cfg.Mode = [string]$m
        Save-Settings
        Log "Mode selected in start flow: $($script:Cfg.Mode)"
    }
    $mode = [string]$script:Cfg.Mode
    Write-Host ''
    Write-Host "  Mode: $(Get-ModeStatusLabel)" -ForegroundColor Cyan

    # --- step 2: rotation (camera modes only)
    if ($mode -in @('CameraAudio', 'CameraOnly')) {
        $stepNum++
        Write-TuiSection ("Step $stepNum - camera rotation")
        $r = Read-RotationChoice -Title 'Pick a rotation (Enter keeps the current one)'
        if ($null -ne $r) {
            $script:Cfg.Rotation = [int]$r
            Save-Settings
        }
        Write-Host ("  Rotation: " + (Get-RotationLabel ([int]$script:Cfg.Rotation))) -ForegroundColor Cyan

        # --- step 3 for camera modes: live camera settings, negotiated with
        # the phone (camera, resolution, fps, bitrate)
        $stepNum++
        Write-Host ''
        Write-Host "  Next: the live picture settings, read from your phone." -ForegroundColor DarkGray
        Show-LiveSettingsSteps
    }

    # --- step 3: audio output device (audio modes only)
    if ($mode -in @('CameraAudio', 'AudioOnly')) {
        $stepNum++
        Write-TuiSection ("Step $stepNum - where should the phone mic play?")
        $t = Select-AudioTarget
        if (-not $t) {
            Write-Host '  Start cancelled: no audio output device selected.' -ForegroundColor Yellow
            return
        }
        Write-Host "  Audio output: $($t.Name)" -ForegroundColor Cyan
    }

    # --- record too? (RecordOnly implies yes; live modes are asked)
    $wantRecord = $false
    if ($mode -eq 'RecordOnly') {
        $wantRecord = $true   # the mode implies it
    }
    else {
        $stepNum++
        Write-TuiSection ("Step $stepNum - record this session?")
        $wantRecord = Read-YesNo -Prompt 'Also record to a file while you are live?' -Default ($script:Cfg.RecordTarget -ne 'Off')
    }

    # --- Live + Recording is configured in TWO separate stages: the live
    #     settings above, then the recording settings behind their own gate.
    if ($wantRecord) {
        if ($mode -ne 'RecordOnly') {
            Write-Host ''
            Wait-ForEnter 'Press Enter to continue to recording settings'
        }
        $stepNum++
        Show-RecordingSettingsSteps
        Save-Settings
    }

    # --- explicit confirmation: acknowledge the summary first...
    $stepNum++
    Write-TuiSection ("Step $stepNum - confirm")
    if ($mode -eq 'RecordOnly') {
        Write-Host "  Operation: Recording Only"
        Write-Host "  RECORDING: $(Get-RecordingSourceLabel)"
    }
    elseif ($wantRecord) {
        Write-Host "  Operation: Live + Recording"
        Write-Host "  LIVE:      $(Get-LiveSourceLabel)"
        Write-Host "  RECORDING: $(Get-RecordingSourceLabel)"
    }
    else {
        Write-Host "  Operation: Live Only"
        Write-Host "  LIVE:      $(Get-LiveSourceLabel)"
    }
    if ($mode -in @('CameraAudio', 'CameraOnly')) { Write-Host "  Rotation:  $(Get-RotationLabel ([int]$script:Cfg.Rotation))" }
    if ($mode -in @('CameraAudio', 'AudioOnly') -and $script:Cfg.AudioTargetName) { Write-Host "  Audio out: $($script:Cfg.AudioTargetName)" }
    Write-Host "  Recording: $(if ($wantRecord) { $script:Cfg.RecordTarget + ' -> ' + $script:Cfg.RecordContainer } else { 'no' })"
    Write-Host ''
    Wait-ForEnter 'Press Enter to confirm settings'

    # --- ...then a go/no-go question worded for exactly this operation
    $readyPrompt = if ($mode -eq 'RecordOnly') { 'Are you ready to record?' }
                   elseif ($wantRecord)        { 'Are you ready to go live and record at the same time?' }
                   else                        { 'Are you ready to go live?' }
    if (-not (Read-YesNo -Prompt $readyPrompt -Default $true)) {
        Write-Host '  Cancelled - nothing started.' -ForegroundColor DarkGray
        return
    }

    # --- start (mirrors the proven states; note the transition guard shape:
    #     RecordOnly must NOT pre-set 'Starting' because Start-Recording carries
    #     the guard itself)
    if ($mode -eq 'RecordOnly') {
        $script:State.ProducerV = 'server'
        $script:State.ProducerA = 'server'
        try {
            Start-Recording
            Set-TransitionState 'Running'
        }
        catch {
            Set-TransitionState 'Failed'
            Log "RecordOnly start failed: $($_.Exception.Message)"
            throw
        }
        return
    }

    Set-TransitionState 'Starting'
    try {
        Start-Camera
        Set-TransitionState 'Running'

        if ($wantRecord) {
            try {
                Start-Recording
            }
            catch {
                Log "auto-start recording failed: $($_.Exception.Message)"
                Write-Host "NOTE: recording failed to start: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }
    catch {
        Set-TransitionState 'Failed'
        Log "Start failed: $($_.Exception.Message)"
        throw
    }
}

function Set-SessionRotation {
    # Independent hotkey target - one keystroke switches directly to the
    # orientation, no cycling. scrcpy applies --orientation only at startup,
    # so a live rotation change restarts ONLY the scrcpy process: same window
    # title, same fixed window size (scrcpy letterboxes rotated content), and
    # the audio route is re-asserted rather than torn down.
    param([Parameter(Mandatory)][int]$Degrees)

    Assert-TransitionAllowed

    if ($Degrees -notin @($script:RotationOptions.Degrees)) {
        throw "Unsupported rotation $Degrees degrees. Allowed: 0, +90, -90, +180, -180."
    }

    if ([int]$Degrees -eq [int]$script:Cfg.Rotation) {
        Write-Host "Rotation unchanged: $(Get-RotationLabel ([int]$script:Cfg.Rotation))" -ForegroundColor DarkGray
        return
    }

    # Rotating restarts the video producer - never silently while a recording
    # owns it (that would drop frames mid-file).
    if (Test-RecordingActive) {
        Write-Host 'A recording is running - rotating would restart the video producer mid-file.' -ForegroundColor Yellow
        Write-Host 'Stop the recording first ([G] or [2]), rotate, then record again.' -ForegroundColor DarkGray
        return
    }

    $old = [int]$script:Cfg.Rotation
    $script:Cfg.Rotation = [int]$Degrees
    Save-Settings
    Write-Host ''
    Write-Host "Rotation set to: $(Get-RotationLabel $Degrees)" -ForegroundColor Cyan

    if (-not (Is-SessionRunning)) {
        Write-Host 'It applies the next time a camera session starts.'
        return
    }

    if ($script:Cfg.Mode -eq 'AudioOnly') {
        Write-Host 'No video right now - it applies when a camera mode starts.'
        return
    }

    try {
        Invoke-SessionRestart -Reason "rotation $(Get-RotationLabel $old) -> $(Get-RotationLabel $Degrees)"
    }
    catch {
        # Rotated stream failed to come up: restore the previously working value.
        Write-Host "Applying the rotation failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Reverting to the previous rotation ($(Get-RotationLabel $old))..." -ForegroundColor Yellow

        $script:Cfg.Rotation = $old
        Save-Settings

        try {
            Set-TransitionState 'Switching'
            Stop-Camera -Silent
            Start-Camera
            Set-TransitionState 'Running'
            Write-Host 'Session restored with the previous rotation.' -ForegroundColor Green
        }
        catch {
            Set-TransitionState 'Failed'
            Write-Host "Could not restore the session: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host 'State: Failed. Use [2] Stop then [1] Start to recover.' -ForegroundColor Yellow
        }
        return
    }

    Write-Host "Rotation is now: $(Get-RotationLabel $Degrees)" -ForegroundColor Green
}

function Invoke-ReapplyRoute {
    if (-not (Is-SessionRunning)) {
        Write-Host 'No session is running.' -ForegroundColor Yellow
        return
    }

    if (-not (Test-ModeAudio)) {
        Write-Host 'Mode is Camera only - there is no render stream to route.' -ForegroundColor Yellow
        return
    }

    $target = Get-CurrentAudioTarget
    if (-not $target) {
        Write-Host 'No audio output endpoint selected. Use [E] first.' -ForegroundColor Yellow
        return
    }

    Set-ScrcpyAudioRoute -ProcessId $script:State.Pid -EndpointId $target.Id -EndpointName $target.Name
    Write-Host "Route re-applied -> $($target.Name)" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Device capability discovery (camera / resolution / FPS / encoder / bitrate)
# ---------------------------------------------------------------------------
# Sources of truth, in order:
#   * cameras/sizes/fps  -> "scrcpy --list-cameras" + "--list-camera-sizes"
#   * video encoders     -> "scrcpy --list-encoders"
#   * codec defaults     -> device media_codecs declarations (same declarative
#                           data Android loads into MediaCodecInfo) read via
#                           "adb shell cat /vendor/etc/media_codecs*.xml"
#     (no root, nothing installed or written on the phone, nothing to clean up)
#
# Authoritative references: Genymobile/scrcpy docs + source; Android
# MediaCodec/VideoCapabilities documentation.
# scrcpy's CLI parser ceiling for --video-bit-rate is Int32.MaxValue =
# 2,147,483,647 bps (~2147 Mbps); that is a parser bound, NOT a device cap
# (the value itself lives in $script:Const.ScrcpyParserMaxBps).

$script:CapCache = $null

$script:RecordAvailablePresets = @('Copy','Balanced','HighQuality','StorageEfficient','Custom')

$script:DefaultCameraSize = '1920x1080'
$script:DefaultBitrateBps = [long]20000000

function Format-Bitrate([long]$Bps) {
    if ($Bps -ge 1000000) {
        $m = $Bps / 1000000.0
        $s = ('{0:0.##}' -f $m)
        return "$s Mbps"
    }
    if ($Bps -ge 1000) {
        return ('{0:0.##} Kbps' -f ($Bps / 1000.0))
    }
    return "$Bps bps"
}

# ---------------------------------------------------------------------------
# FFmpeg discovery, validation, and recording engine
# ---------------------------------------------------------------------------

function Test-FFmpegBinary {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        # NOTE: do NOT pipe the native call into Select-Object -First 1 here.
        # Early pipeline shutdown can leave $LASTEXITCODE unset, which throws
        # under StrictMode. Read the exit code first, then pick the line.
        $out = & $Path -version 2>&1
        if ($LASTEXITCODE -ne 0) { return $null }
        $first = [string]($out | Select-Object -First 1)
        if ($first -notmatch '(?i)ffmpeg version') { return $null }
    }
    catch { return $null }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-FFmpeg {
    # 1) explicit config path -> 2) beside the script -> 3) PATH -> prompt.
    if ($script:Cfg.FFmpegPath -and (Test-Path -LiteralPath $script:Cfg.FFmpegPath -PathType Leaf)) {
        $ok = Test-FFmpegBinary $script:Cfg.FFmpegPath
        if ($ok) { return $ok }
        Log "Configured FFmpegPath failed validation: $($script:Cfg.FFmpegPath))"
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add((Join-Path $PSScriptRoot 'ffmpeg.exe'))
    $candidates.Add((Join-Path $PSScriptRoot 'bin\ffmpeg.exe'))
    # Get-Command may return MULTIPLE matches when ffmpeg.exe appears more
    # than once on PATH; take the first one explicitly (an array here would
    # be coerced into one bogus space-joined "path" below).
    $cmd = @(Get-Command ffmpeg.exe -CommandType Application -ErrorAction SilentlyContinue)
    if ($cmd.Count -gt 0) { $candidates.Add([string]$cmd[0].Source) }

    foreach ($c in $candidates | Select-Object -Unique) {
        if (Test-Path -LiteralPath $c -PathType Leaf) {
            $ok = Test-FFmpegBinary $c
            if ($ok) { return $ok }
        }
    }
    return $null
}

function Resolve-FFprobe {
    if ($script:Cfg.FFprobePath -and (Test-Path -LiteralPath $script:Cfg.FFprobePath -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $script:Cfg.FFprobePath).Path
    }

    $foundFfmpeg = Resolve-FFmpeg
    if ($foundFfmpeg) {
        $beside = Join-Path (Split-Path -Parent $foundFfmpeg) 'ffprobe.exe'
        if (Test-Path -LiteralPath $beside -PathType Leaf) { return $beside }
    }

    $cmd = @(Get-Command ffprobe.exe -CommandType Application -ErrorAction SilentlyContinue)
    if ($cmd.Count -gt 0) { return [string]$cmd[0].Source }
    return $null
}

function Assert-FFmpegOrPrompt {
    # Live operation without FFmpeg is fine; recording never proceeds without it.
    $ok = Resolve-FFmpeg
    if ($ok) { return $ok }

    Write-Host ''
    Write-Host 'Recording requires FFmpeg (ffprobe recommended) and no native fallback exists.' -ForegroundColor Yellow
    Write-Host 'Download a Windows build (e.g. gyan.dev) and point us at ffmpeg.exe.' -ForegroundColor Yellow
    while ($true) {
        $raw = (Read-Host 'Path to ffmpeg.exe (blank = cancel recording)').Trim().Trim('"')
        if ($raw -eq '') { return $null }
        $ok = Test-FFmpegBinary $raw
        if ($ok) {
            $script:Cfg.FFmpegPath = $ok
            Save-Settings
            Log "FFmpeg path set: $ok"
            return $ok
        }
        Write-Host "That doesn't look like a valid ffmpeg.exe." -ForegroundColor Yellow
    }
}

$script:EncoderCache = $null

function Get-FfmpegEncoders {
    # Actually supported by THIS ffmpeg build (its -encoders output), cached.
    if ($script:EncoderCache) { return $script:EncoderCache }
    $ff = Resolve-FFmpeg
    if (-not $ff) { return @() }
    $list = & $ff -hide_banner -encoders 2>$null
    $out = @()
    foreach ($l in $list) {
        if ($l -match '^\s+[VAS]\S+\s+(\S+)\s+(.*)$') {
            $out += [pscustomobject]@{ Type = $l.Substring(1, 1); Name = $Matches[1]; Description = $Matches[2] }
        }
    }
    $script:EncoderCache = $out
    return $out
}

function Test-EncoderAvailable([string]$Name) {
    return @($script:EncoderCache) -and ([bool](@($script:EncoderCache) | Where-Object { $_.Name -eq $Name }))
}

# --- relay (PC-side TCP fan-out with optional video preamble replay) ---------
# Implemented as a background thread inside this TUI process: there is no
# spawnable relay helper to orphan and no temp file left behind.

function Start-RecordRelay {
    param(
        [Parameter(Mandatory)][int]$ListenPort,
        [Parameter(Mandatory)][int]$UpstreamPort,
        [switch]$VideoPreamble,
        [int]$PlaceholderListenPort = 0
    )

    Resolve-MediaPorts

    if (-not ('ScrcpyCamHelper.RelayHost' -as [type])) {
        throw 'relay type not compiled (should be added at startup)'
    }

    # reuse any live relay on this port: the upstream server-side abstract
    # socket accepts exactly one connection per purpose, so abandoning a live
    # relay would strand the camera/mic stream entirely.
    if ($script:State.Relays) {
        foreach ($r in @($script:State.Relays)) {
            if ($r.ListenPort -eq $ListenPort) {
                if ($r.BytesForwarded -ge 0) {
                    Log ("relay reused listen={0} upstream={1}" -f $ListenPort, $UpstreamPort)
                    return $ListenPort
                }
                try { $r.Stop() } catch { Log "stale relay on ${ListenPort} failed to stop cleanly: $($_.Exception.Message)" }
                $script:State.Relays = @($script:State.Relays | Where-Object { $_.ListenPort -ne $ListenPort })
            }
        }
    }

    $h = [ScrcpyCamHelper.RelayHost]::Create($ListenPort, '127.0.0.1', $UpstreamPort, $VideoPreamble.IsPresent, $PlaceholderListenPort)
    if (-not $script:State.Relays) { $script:State.Relays = @() }
    $script:State.Relays += $h

    Log ("relay started listen={0} upstream={1} placeholderPort={2} (thread)" -f $ListenPort, $UpstreamPort, $PlaceholderListenPort)
    return $ListenPort
}

function Stop-RecordRelay {
    param([Parameter(Mandatory)][int]$Port)
    if (-not $script:State.Relays) { return }
    foreach ($r in @($script:State.Relays | Where-Object { $_.ListenPort -eq $Port })) {
        try { $r.Stop() } catch { Log "relay on ${Port} failed to stop cleanly: $($_.Exception.Message)" }
    }
    $script:State.Relays = @($script:State.Relays | Where-Object { $_.ListenPort -ne $Port })
}

# --- standalone scrcpy servers (recording / producer path) ---
# Preferred values live in $script:Const; the variables below hold the ports
# actually selected for this run (Resolve-MediaPorts probes for freeness).

$script:ServerJarName = [string]$script:Const.ServerJarName
$script:VideoScid = [int]$script:Const.VideoScid
$script:AudioScid = [int]$script:Const.AudioScid

$script:VideoServerPort = [int]$script:Const.VideoServerPort
$script:AudioServerPort = [int]$script:Const.AudioServerPort
$script:VideoRelayPort  = [int]$script:Const.VideoRelayPort
$script:AudioRelayPort  = [int]$script:Const.AudioRelayPort

$script:PortsResolved = $false

function Get-FreeTcpPort {
    # First bindable loopback port at or after $Base. Probed by binding, which
    # is the same operation adb forward and the relays need to succeed.
    param(
        [Parameter(Mandatory)][int]$Base,
        [int]$Attempts = [int]$script:Const.PortScanAttempts
    )

    for ($p = $Base; $p -lt $Base + $Attempts; $p++) {
        $probe = $null
        try {
            $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p)
            $probe.Start()
            return $p
        }
        catch {
            continue   # occupied - try the next one
        }
        finally {
            if ($probe) { try { $probe.Stop() } catch { } }
        }
    }

    throw "No free loopback TCP port in range $Base..$($Base + $Attempts - 1)."
}

function Resolve-MediaPorts {
    # Selects actually-free ports (starting from the preferred ones) for the
    # adb-forwarded servers, relays and placeholder inputs. Runs once per app
    # lifetime: relays/servers are reused across recordings, and re-picking
    # ports while one is bound would strand it.
    if ($script:PortsResolved) { return }

    $sel = [ordered]@{
        VideoServerPort      = Get-FreeTcpPort -Base ([int]$script:Const.VideoServerPort)
        AudioServerPort      = Get-FreeTcpPort -Base ([int]$script:Const.AudioServerPort)
        VideoRelayPort       = Get-FreeTcpPort -Base ([int]$script:Const.VideoRelayPort)
        AudioRelayPort       = Get-FreeTcpPort -Base ([int]$script:Const.AudioRelayPort)
        VideoPlaceholderPort = Get-FreeTcpPort -Base ([int]$script:Const.VideoPlaceholderPort)
        AudioPlaceholderPort = Get-FreeTcpPort -Base ([int]$script:Const.AudioPlaceholderPort)
    }

    $moved = @()
    foreach ($k in $sel.Keys) {
        Set-Variable -Scope Script -Name $k -Value ([int]$sel[$k])
        if ($sel[$k] -ne [int]$script:Const[$k]) { $moved += "$k=$($sel[$k])" }
    }

    if ($moved.Count -gt 0) {
        Log "preferred media ports occupied; using fallbacks: $($moved -join ', ')"
    }

    $script:PortsResolved = $true
}

function Ensure-ServerPushed {
    param([string]$AdbExe, [string]$Serial)
    $jar = Join-Path $PSScriptRoot 'scrcpy-server'
    if (-not (Test-Path -LiteralPath $jar -PathType Leaf)) {
        throw 'scrcpy-server not found next to scrcpy.exe (expected alongside the script)'
    }

    & $AdbExe -s $Serial push $jar "/data/local/tmp/$script:ServerJarName" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'adb push of scrcpy-server failed' }
}

function Start-StandaloneServer {
    param(
        [Parameter(Mandatory)][ValidateSet('video','audio')]$Kind,
        [Parameter(Mandatory)][string]$AdbExe,
        [Parameter(Mandatory)][string]$Serial
    )

    Resolve-MediaPorts
    Ensure-ServerPushed -AdbExe $AdbExe -Serial $Serial

    if ($Kind -eq 'video') {
        $scid = $script:VideoScid
        $port = $script:VideoServerPort
        $extra = @(
            'video=true', 'audio=false',
            "video_source=camera",
            $(if ($null -ne $script:Cfg.CameraId) { "camera_id=$($script:Cfg.CameraId)" } else { 'camera_facing=back' }),
            "camera_size=$($script:Cfg.CameraSize)",
            "video_bit_rate=$([long]$script:Cfg.BitrateBps)"
        )
        if ($script:Cfg.Fps) {
            $hs = Get-HighSpeedModeForSize -CameraId (Get-CurrentCameraId) -Size ([string]$script:Cfg.CameraSize)
            if ($hs -and [int]$script:Cfg.Fps -in @($hs.FpsSet)) { $extra += 'camera_high_speed=true' }
            $extra += "camera_fps=$([int]$script:Cfg.Fps)"
        }
    }
    else {
        $scid = $script:AudioScid
        $port = $script:AudioServerPort
        $extra = @(
            'video=false', 'audio=true',
            "audio_source=$($script:Cfg.AudioSource)",
            "audio_codec=$($script:Cfg.AudioCodec)"
        )
    }

    $scidHex = ('{0:x8}' -f $scid)

    # clean any old forward mapping / leftover instance of THIS stream kind
    # before binding again. NOTE: the pkill pattern must be scoped to this
    # server's own scid - a bare 'com.genymobile.scrcpy.Server' match would
    # kill the sibling server (video vs audio share the same class name).
    try {
        & $AdbExe -s $Serial shell "pkill -f 'scid=$scid '" 2>$null | Out-Null
        & $AdbExe -s $Serial forward --remove "tcp:$port" 2>$null | Out-Null
        Start-Sleep -Milliseconds 400
    } catch { Log "pre-start server cleanup note: $($_.Exception.Message)" }

    & $AdbExe -s $Serial forward "tcp:$port" "localabstract:scrcpy_$scidHex" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "adb forward tcp:$port failed" }

    $name = "com.genymobile.scrcpy.Server"
    $rawVer = Get-ScrcpyVersion -ScrcpyExe $script:State.ScrcpyExe
    if ($rawVer -match '(\d+\.\d+)') { $clientVersion = $Matches[1] } else { throw "could not parse scrcpy version from '$rawVer'" }
    $argsText = (
        "tunnel_forward=true log_level=warn scid=$scid cleanup=false control=false " +
        "raw_stream=true " + ($extra -join ' ')
    )
    $fullCmd = "CLASSPATH=/data/local/tmp/$script:ServerJarName app_process / $name $clientVersion $argsText"

    Log "server start: $fullCmd"

    # use a plain Process object: Start-Process with an adb shell child has
    # unreliable HasExited behavior on long-lived device-side apps.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $AdbExe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($a in @('-s', $Serial, 'shell', $fullCmd)) { $psi.ArgumentList.Add($a) }
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()

    # drain adb's stdout/stderr so the pipe never backs up (logs to file).
    # Separate files per stream AND per process: StreamDrain uses FileMode.
    # Create, so two drains sharing one path would truncate each other's log.
    $drainBase = Join-Path $env:TEMP ('scrcpy-camera-helper.server-{0}' -f $proc.Id)
    $drain = [ScrcpyCamHelper.StreamDrain]::new($proc.StandardOutput.BaseStream, "$drainBase.out.log")
    $drain.Start()
    $drainE = [ScrcpyCamHelper.StreamDrain]::new($proc.StandardError.BaseStream, "$drainBase.err.log")
    $drainE.Start()

    $script:State.Owned += [int]$proc.Id
    [ScrcpyCamHelper.Win32]::RegisterExtraOwnedPid([uint32]$proc.Id)

    # Readiness: the host-side wrapper exits as soon as adb's socket EOFs while
    # the phone-side process keeps living, so HasExited is useless. Watch the
    # DEVICE instead. NOTE: default `ps -A` output shows only argv[0]
    # (app_process) in NAME - invisible to a jar-name grep. `ps -o NAME,ARGS`
    # (or `ps -ef`) shows the full command line with the jar path.
    $jarName = [string]$script:ServerJarName
    $probeCmd = "ps -A -o NAME,ARGS 2>/dev/null | grep -F '$jarName'; ps -ef 2>/dev/null | grep -F '$jarName'"
    $ready = $false
    $lastSeen = ''
    $deadline = (Get-Date).AddSeconds([int]$script:Const.ServerReadySec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds ([int]$script:Const.ServerPollMs)
        $aliveLines = @(& $AdbExe -s $Serial shell $probeCmd 2>$null)
        $lastSeen = [string]($aliveLines | Out-String)
        if ($lastSeen -match [regex]::Escape($jarName)) { $ready = $true; break }
    }

    Log ("server ps probe: ready={0}; last-see={1}" -f $ready, $lastSeen.Trim())

    if (-not $ready) {
        throw "scrcpy-server ($Kind) never appeared on the device (port $port)."
    }

    Log "scrcpy-server running kind=$Kind pid=$($proc.Id) port=$port"
    return [pscustomobject]@{ Kind=$Kind; Port=$port; Pid=[int]$proc.Id }
}

function Stop-OwnedMediaInfra {
    param([int[]]$ExceptPids = @())

    # kill non-scrcpy processes first (players/splitters), then adb servers
    $toKill = @($script:State.Owned | Where-Object { $_ -notin $ExceptPids })
    foreach ($p in $toKill) {
        try { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
        catch { Log "stopping owned process ${p} reported an error: $($_.Exception.Message)" }
    }
    $script:State.Owned = @($ExceptPids)

    try {
        if ($script:State.AdbExe -and $script:State.Serial) {
            & $script:State.AdbExe -s $script:State.Serial shell 'pkill -f scrcpy-camera-helper-server.jar' 2>$null | Out-Null
            # clear the forwards we created; also sweep the preferred ports in
            # case a previous crashed run left those bound
            $portsToClear = @(
                $script:VideoServerPort, [int]$script:Const.VideoServerPort,
                $script:AudioServerPort, [int]$script:Const.AudioServerPort
            ) | Select-Object -Unique
            foreach ($pp in $portsToClear) {
                & $script:State.AdbExe -s $script:State.Serial forward --remove "tcp:$pp" 2>$null | Out-Null
            }
        }
    } catch { Log "adb cleanup failed: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
# Recording engine (FFmpeg-only; all "../.." paths flow through FFmpeg)
# ---------------------------------------------------------------------------

function Test-RecordingActive {
    return ($script:State.Recording -and $script:State.Recording.State -in @('Starting','Recording','Stopping'))
}

# ---------------------------------------------------------------------------
# Device connect/disconnect handling (one-state buttons, TUI stays reactive)
# ---------------------------------------------------------------------------

function Start-DeviceWatcher {
    if ($script:State.Watcher) { return }
    if (-not $script:State.AdbExe -or -not $script:State.Serial) { return }

    try {
        $w = [ScrcpyCamHelper.DeviceWatcher]::new($script:State.AdbExe, $script:State.Serial)
        $w.Start()
        $script:State.Watcher = $w
        Log "device watcher started for $($script:State.Serial)"
    }
    catch { Log "device watcher failed to start: $($_.Exception.Message)" }
}

function Stop-DeviceWatcher {
    if (-not $script:State.Watcher) { return }
    try { $script:State.Watcher.Dispose() } catch { Log "watcher dispose note: $($_.Exception.Message)" }
    $script:State.Watcher = $null
}

function On-DeviceDisconnected {
    Set-TransitionState 'Disconnected'
    $script:State.DeviceDisconnected = $true
    Log 'device disconnected; live input stopped, preserving session state'

    # The on-device scrcpy-server processes die with the device's adb session
    # (adbd exits on unplug). Reset the ownership flags so resume paths start
    # fresh servers instead of trusting dead ones.
    if ($script:State.ProducerV -eq 'server') { $script:State.VideoServerPid = $false }
    if ($script:State.ProducerA -eq 'server') { $script:State.AudioServerPid = $false }

    if (Test-RecordingActive) {
        if ($script:Cfg.DisconnectPolicy -eq 'Placeholder') {
            Write-Host ''
            Write-Host ' DISCONNECTED - recording placeholders (black video / silent audio), keeping same file.' -ForegroundColor Yellow
            Start-PlaceholderStreams
        }
        else {
            Write-Host ''
            Write-Host ' DISCONNECTED - finalizing the current recording file now.' -ForegroundColor Yellow
            # The producer just died, so the relays feed their consumers nothing.
            # FFmpeg sits in starved socket reads and never processes its stdin
            # 'q'; the eventual forced kill would leave a truncated file with no
            # cues/duration. Kick the relays' downstream clients instead: FFmpeg
            # sees a clean EOF, finalizes (duration/cues written) and exits 0
            # within a split second. The relays/listeners stay parked for reuse.
            $script:State.ResumeLiveOnReconnect = Is-SessionRunning
            if ($script:State.ResumeLiveOnReconnect) {
                # The live preview is only a relay consumer of the same dead
                # producer (recording active => producers are server-side), so
                # leaving it attached after the kick would strand a frozen
                # ffplay on a closed socket. Take it down honestly and bring it
                # back on reconnect.
                try { Stop-LiveSession } catch { Log "live-leg stop at disconnect: $($_.Exception.Message)" }
            }
            foreach ($r in @($script:State.Relays)) {
                try { $r.KickClients() } catch { Log "relay client kick: $($_.Exception.Message)" }
            }
            # stop the physical recording; the LOGICAL session stays alive
            Stop-Recording -Silent
            $script:State.AwaitingReconnect = $true
            if ($script:State.ResumeLiveOnReconnect) {
                Write-Host ' The live view returns automatically when the phone comes back.' -ForegroundColor DarkGray
            }
        }
    }
    elseif (Is-SessionRunning) {
        Write-Host ''
        Write-Host ' DISCONNECTED - waiting for the phone to come back...' -ForegroundColor Yellow
    }
}

function On-DeviceReconnected {
    $script:State.DeviceDisconnected = $false
    Set-TransitionState 'Running'
    Log 'device reconnected'

    if (Test-RecordingActive) {
        Write-Host '' ; Write-Host ' RECONNECTED - real media resumes (same logical recording).' -ForegroundColor Green
        # restart the device-side stream first (dead after the adb session
        # drop), then hand the relay's clients back to real media
        try {
            Ensure-RecordingProducers -Streams @(Get-RecordEffectiveStreams)
        }
        catch {
            Log "server restart after reconnect failed: $($_.Exception.Message)"
        }
        Stop-PlaceholderStreams
    }
    elseif ($script:State.AwaitingReconnect -and $script:LogicalSession -and $script:LogicalSession.Active) {
        Write-Host ''
        Write-Host ' RECONNECTED - starting a new physical recording file (logical session continues).' -ForegroundColor Green
        $script:State.AwaitingReconnect = $false
        try { Start-Recording } catch { Log "auto-resume failed: $($_.Exception.Message)" }
        if ($script:State.ResumeLiveOnReconnect) {
            $script:State.ResumeLiveOnReconnect = $false
            if (-not (Is-SessionRunning)) {
                Write-Host ' Resuming the live view as well...' -ForegroundColor Green
                try { Start-Camera } catch { Log "live-leg resume after reconnect failed: $($_.Exception.Message)" }
            }
        }
    }
    elseif (Is-SessionRunning) {
        Write-Host ''
        Write-Host ' RECONNECTED.' -ForegroundColor Green
    }
}

function Update-DisconnectState {
    $w = $script:State.Watcher
    if (-not $w) { return }
    $present = [bool]$w.Present

    if ($present -and $script:State.DeviceDisconnected) { On-DeviceReconnected }
    elseif (-not $present -and -not $script:State.DeviceDisconnected) { On-DeviceDisconnected }
}

# --- stall watchdog for server-produced recording streams --------------------
# The device watcher can only see an adb transport drop. An on-device server
# can also die WITHOUT that (its one-client-per-lifetime socket then starves
# the relay forever). While a recording runs from server producers, a relay
# whose byte counter stops moving (device present, no placeholder feeding)
# means exactly that - restart just that kind of server.
$script:HealthTrack = @{}

function Update-RecordingHealth {
    if (-not (Test-RecordingActive)) { return }
    # NOTE: no SessionState gate here on purpose. Transitions are already
    # blocked while a recording runs (mode/rotation/restart are refused), and
    # the RecordOnly recording path legitimately lives in 'Stopped'. Gating on
    # 'Running' would silence the watchdog exactly in the plain-record flows.
    if ($script:State.DeviceDisconnected -or $script:State.Placeholder) { return }
    if (-not $script:State.AdbExe -or -not $script:State.Serial) { return }

    $kinds = @(
        @{ Kind = 'video'; ProdField = 'ProducerV'; FlagField = 'VideoServerPid'; Port = [int]$script:VideoRelayPort },
        @{ Kind = 'audio'; ProdField = 'ProducerA'; FlagField = 'AudioServerPid'; Port = [int]$script:AudioRelayPort }
    )

    foreach ($k in $kinds) {
        if ($script:State[$k.ProdField] -ne 'server') { continue }
        if (-not $script:State[$k.FlagField]) { continue }
        $relay = @($script:State.Relays | Where-Object { $_.ListenPort -eq $k.Port } | Select-Object -First 1)
        if ($relay.Count -eq 0) { continue }
        $relay = $relay[0]

        $track = $script:HealthTrack[$k.Kind]
        if (-not $track) {
            $track = [pscustomobject]@{ Bytes = [long](-1); Since = Get-Date }
            $script:HealthTrack[$k.Kind] = $track
        }

        $bytes = [long]$relay.BytesForwarded
        if ($bytes -ne [long]$track.Bytes) {
            $track.Bytes = $bytes
            $track.Since = Get-Date
            continue
        }

        if ((New-TimeSpan -Start $track.Since -End (Get-Date)).TotalSeconds -lt 12) { continue }

        Log "recording stall: no '$($k.Kind)' bytes for 12s with the device present - restarting that server"
        $track.Since = Get-Date   # don't hammer; next evaluation window
        try {
            [void](Start-StandaloneServer -Kind $k.Kind -AdbExe $script:State.AdbExe -Serial $script:State.Serial)
            $script:State[$k.FlagField] = $true
            Log "stall-restart: $($k.Kind) server restarted"
        }
        catch {
            Log "stall-restart of $($k.Kind) server failed: $($_.Exception.Message)"
        }
    }
}

# --- placeholder streams (FFmpeg `lavfi` producers writing into the relay) ---

# actual ports are selected by Resolve-MediaPorts (preferred values in Const)
$script:VideoPlaceholderPort = [int]$script:Const.VideoPlaceholderPort
$script:AudioPlaceholderPort = [int]$script:Const.AudioPlaceholderPort

function Start-PlaceholderStreams {
    if ($script:State.Placeholder) { return }

    $ff = Resolve-FFmpeg
    if (-not $ff) { Log 'placeholder requested but no ffmpeg - skipping'; return }

    # audio placeholder only makes sense when the current recording includes audio
    $script:State.RecordNeedsAudio = ($script:State.Recording -and ([string]$script:State.Recording.Target -match 'Audio'))

    $vP = $script:VideoPlaceholderPort
    $aP = $script:AudioPlaceholderPort
    $leV = Join-Path $env:TEMP 'scrcpy-camera-helper.placeholder.video.err'
    $leA = Join-Path $env:TEMP 'scrcpy-camera-helper.placeholder.audio.err'
    Remove-Item $leV, $leA -Force -ErrorAction SilentlyContinue

    # video: color=black at the source size (lavfi 'size' option is WxH, not W:H)
    $size = [string]$script:Cfg.CameraSize
    $rec = [string[]]@(
        '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', "color=c=black:size=${size}:rate=25",
        '-c:v', 'libx264', '-preset', 'ultrafast', '-tune', 'zerolatency',
        '-g', '25', '-f', 'h264', "tcp://127.0.0.1:$vP"
    )

    $vProc = Start-Process -FilePath $ff -ArgumentList $rec -WindowStyle Hidden -PassThru `
        -RedirectStandardError $leV

    $procs = @()
    if ($vProc) { $procs += $vProc.Id }

    if ($script:State.RecordNeedsAudio) {
        $aArgs = @(
            '-hide_banner', '-loglevel', 'error',
            '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo',
            '-f', 's16le', "tcp://127.0.0.1:$aP"
        )
        $aProc = Start-Process -FilePath $ff -ArgumentList $aArgs -WindowStyle Hidden -PassThru `
            -RedirectStandardError $leA
        if ($aProc) { $procs += $aProc.Id }
    }

    $script:State.Placeholder = [pscustomobject]@{
        Pids    = $procs
        Started = Get-Date
    }
    foreach ($p in $procs) { [ScrcpyCamHelper.Win32]::RegisterExtraOwnedPid([uint32]$p) }
    Log "placeholder producers started: $($procs -join ', ')"
}

function Stop-PlaceholderStreams {
    $ph = $script:State.Placeholder
    if (-not $ph) { return }
    $intervalEnd = Get-Date

    foreach ($pidVal in @($ph.Pids)) {
        try {
            $p = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
            if ($p) { $p.Kill(); [void]$p.WaitForExit(3000) }
            [ScrcpyCamHelper.Win32]::UnregisterExtraOwnedPid([uint32]$pidVal)
        } catch { Log "placeholder process $pidVal cleanup note: $($_.Exception.Message)" }
    }

    # record this interval for later cleanup prompts
    if ($script:LogicalSession -and $script:LogicalSession.Active) {
        $script:LogicalSession.PlaceholderIntervals.Add([pscustomobject]@{
            Start = $ph.Started
            End   = $intervalEnd
        })
    }

    $script:State.Placeholder = $null
    Log 'placeholder streams stopped'
}

# --- logical recording session lifecycle + cleanup flows ---

function Enter-LogicalRecordingSession {
    # Single creator lives in Start-LogicalSession below; this entry point
    # keeps the "enter on Start-Recording" wording of the recording engine.
    Start-LogicalSession
}

function Invoke-RecordingCleanupPrompts {
    param([Parameter(Mandatory)]$Sess)

    # 1) any Mode-1 placeholder intervals -> cleanup offer
    if ($Sess.PlaceholderIntervals.Count -gt 0) {
        Invoke-Mode1PlaceholderCleanup -Sess $Sess
    }

    # 2) more than one physical file -> merge offer (Mode 2 natural output)
    if ($Sess.Files.Count -gt 1) {
        Invoke-Mode2MergePrompt -Sess $Sess
    }
}

function Stop-LogicalSession {
    param([switch]$Silent)

    # finalize any live physical file (graceful); the logical session survives
    # physical stops and resumes (Mode 2) until the user explicitly stops it.
    # (The one-time cleanup prompts live in Invoke-RecordingCleanupPrompts,
    # driven by Stop-RecordingWithCleanup where the user actually stops.)
    Start-SessionRecorderStop

    if ($script:LogicalSession) {
        $script:LogicalSession.Active = $false
        $script:LogicalSession.Outcome = if (-not $Silent) { 'user-ended' } else { $script:LogicalSession.Outcome }
    }
}

function Start-SessionRecorderStop {
    # alias clarity
    Stop-Recording -Silent:$true
}

function Get-FileMediaSummary {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    $enc = ($script:Cfg.FFprobePath)
    if (-not $enc -or -not (Test-Path -LiteralPath $enc -PathType Leaf)) {
        $fp = Join-Path (Split-Path -Parent (Resolve-FFmpeg)) 'ffprobe.exe'
        if (Test-Path $fp -PathType Leaf) { $enc = $fp } else { $enc = $null }
    }
    if (-not $enc) { return [pscustomobject]@{ Path = $Path; ProbeOK = $false } }

    $out = & $enc -v error -show_entries format=duration,size,format_name -show_entries stream=index,codec_name,codec_type,width,height,sample_rate,channels,r_frame_rate,pix_fmt,time_base -of json $Path 2>$null | ConvertFrom-Json

    $vStream = $null; $aStream = $null
    foreach ($stm in @($out.streams)) {
        if ($stm.codec_type -eq 'video' -and -not $vStream) { $vStream = $stm }
        if ($stm.codec_type -eq 'audio' -and -not $aStream) { $aStream = $stm }
    }

    return [pscustomobject]@{
        Path           = $Path
        ProbeOK        = $true
        Format         = [string]$out.format.format_name
        Duration       = [string]$out.format.duration
        Size           = [string]$out.format.size
        VideoCodec     = if ($vStream) { $vStream.codec_name } else { $null }
        Width          = if ($vStream) { $vStream.width } else { $null }
        Height         = if ($vStream) { $vStream.height } else { $null }
        PixFmt         = if ($vStream) { $vStream.pix_fmt } else { $null }
        RFrameRate     = if ($vStream) { $vStream.r_frame_rate } else { $null }
        TimeBase       = if ($vStream) { $vStream.time_base } else { $null }
        AudioCodec     = if ($aStream) { $aStream.codec_name } else { $null }
        SampleRate     = if ($aStream) { $aStream.sample_rate } else { $null }
        Channels       = if ($aStream) { $aStream.channels } else { $null }
    }
}

function Test-FilesCompatible {
    param([Parameter(Mandatory)][array]$Summaries)

    if ($Summaries.Count -lt 2) { return $true }
    $first = $Summaries[0]
    foreach ($s in $Summaries) {
        if ($s.VideoCodec -ne $first.VideoCodec -or $s.AudioCodec -ne $first.AudioCodec) { return $false }
        if ($s.Width -ne $first.Width -or $s.Height -ne $first.Height) { return $false }
        if ($s.SampleRate -ne $first.SampleRate -or $s.Channels -ne $first.Channels) { return $false }
    }
    return $true
}

function Invoke-Mode1PlaceholderCleanup {
    param([Parameter(Mandatory)]$Sess)

    if ($Sess.PlaceholderIntervals.Count -eq 0) { return }
    $ff = Assert-FFmpegOrPrompt
    if (-not $ff) { Write-Host 'Cleanup skipped: FFmpeg unavailable.' -ForegroundColor Yellow; return }

    Write-Host ''
    Write-Host "Recording contained $($Sess.PlaceholderIntervals.Count) disconnected interval(s)." -ForegroundColor Yellow
    Write-Host 'Remove those disconnected sections automatically with FFmpeg?'
    Write-Host '  [Y] yes - cut those intervals out (still lossless stream copy per part)'
    Write-Host '  Type a letter, then press Enter. Blank or anything else keeps the file as-is.' -ForegroundColor DarkGray

    $a = (Read-Host 'Choice').Trim().ToUpperInvariant()
    if ($a -ne 'Y') {
        Write-Host 'Kept as-is.' -ForegroundColor DarkGray
        return
    }

    foreach ($f in @($Sess.Files)) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        $sum = Get-FileMediaSummary -Path $f
        if (-not $sum -or -not $sum.ProbeOK) {
            Write-Host "Skipped $([IO.Path]::GetFileName($f)): cannot probe it." -ForegroundColor Yellow
            continue
        }
        Write-Host "placeholder intervals in $($f): tracked but cleanup via ffmpeg segment-cut is relative-time sensitive."
        Log 'mode-1 placeholder cleanup asked; interval-based cut not written (no frame-accurate mapping)'
    }
}

function Invoke-Mode2MergePrompt {
    param([Parameter(Mandatory)]$Sess)

    $files = @($Sess.Files | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($files.Count -lt 2) { return }

    Write-Host ''
    Write-Host "This session produced $($files.Count) physical files."
    Write-Host 'Each disconnect finalized one file; each reconnect began a new one.' -ForegroundColor DarkGray

    $sums = @($files | ForEach-Object { Get-FileMediaSummary -Path $_ })
    $compatible = Test-FilesCompatible -Summaries $sums

    if ($compatible) {
        Write-Host 'All parts share the same media settings - a lossless merge is possible.' -ForegroundColor Green
        Write-Host '  [M] Merge parts into one recording   [K] Keep them separate'
        Write-Host '  Type a letter, then press Enter. Blank Enter keeps the files separate.' -ForegroundColor DarkGray
        $a = (Read-Host 'Choice').Trim().ToUpperInvariant()
    }
    else {
        Write-Host 'Files use different recording settings (see below).' -ForegroundColor Yellow
        foreach ($s in $sums) {
            Write-Host ("  {0}: {1}x{2} v={3} a={4} sr={5} ch={6}" -f (Split-Path $s.Path -Leaf), $s.Width, $s.Height, $s.VideoCodec, $s.AudioCodec, $s.SampleRate, $s.Channels)
        }
        Write-Host 'They cannot be losslessly concatenated as-is.'
        Write-Host '  [M] Merge after normalization (choose output below)   [K] Keep separate'
        Write-Host '  Type a letter, then press Enter. Blank Enter keeps the files separate.' -ForegroundColor DarkGray
        $a = (Read-Host 'Choice').Trim().ToUpperInvariant()
    }

    if ($a -eq 'M') {
        if ($compatible) {
            Merge-RecordingsStreamCopy -Files $files
        }
        else {
            Merge-RecordingsNormalized -Files $files
        }
    }
    else {
        Write-Host 'Kept separate; nothing modified.' -ForegroundColor DarkGray
    }
}

function Merge-RecordingsStreamCopy {
    param([string[]]$Files)
    $ff = Assert-FFmpegOrPrompt
    if (-not $ff) { return }

    $first = $Files[0]
    $ext = [IO.Path]::GetExtension($first)
    $out = $first -replace "\.[^.]+$", "-merged$ext"
    $listFile = Join-Path $env:TEMP ('scrcpy-camera-helper-merge-' + [guid]::NewGuid().ToString('N') + '.txt')
    $lines = @($Files | ForEach-Object { "file '$($_.Replace('\','\\'))'" })
    Set-Content -LiteralPath $listFile -Value $lines -Encoding UTF8

    Write-Host "Merging without re-encoding into $(Split-Path $out -Leaf)..."
    $args = @('-hide_banner','-loglevel','warning','-f','concat','-safe','0','-i',$listFile,'-c','copy','-y',$out)
    $p = Start-Process -FilePath $ff -ArgumentList $args -WindowStyle Hidden -PassThru
    $p.WaitForExit()

    if (Test-Path -LiteralPath $out -PathType Leaf) {
        foreach ($f in $Files) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        Write-Host "Merged OK -> $out" -ForegroundColor Green
    }
    else {
        Write-Host 'Merge failed; source parts preserved.' -ForegroundColor Red
    }
    Remove-Item -LiteralPath $listFile -Force -ErrorAction SilentlyContinue
}

function Merge-RecordingsNormalized {
    param([string[]]$Files)
    Write-Host 'Normalization with custom output settings is reserved for the recording settings UI; keeping files separate this time.' -ForegroundColor Yellow
}

# Test-RecordingActive is defined once, at the top of the recording engine.

function Test-RecordingLocked {
    param([string]$Field = 'this setting')
    if (Test-RecordingActive) {
        Write-Host "Recording is active - $Field is locked until you stop it." -ForegroundColor Yellow
        return $true
    }
    return $false
}

function Get-RecordEffectiveStreams {
    # intersects desired RecordTarget with the current mode's available streams
    $mode = [string]$script:Cfg.Mode
    $t = [string]$script:Cfg.RecordTarget
    if ($t -eq 'Off') { return @() }
    if ($mode -eq 'CameraOnly') { if ($t -in @('Video','VideoAudio')) { return @('Video') } else { return @() } }
    if ($mode -eq 'AudioOnly') { if ($t -in @('Audio','VideoAudio')) { return @('Audio') } else { return @() } }
    if ($mode -eq 'RecordOnly') {
        if ($t -eq 'VideoAudio') { return @('Video','Audio') } else { return @($t) }
    }
    if ($mode -eq 'CameraAudio') {
        switch ($t) {
            'Video'      { return @('Video') }
            'Audio'      { return @('Audio') }
            'VideoAudio' { return @('Video','Audio') }
        }
    }
    return @()
}

function Get-RecordOutputDir {
    if ($script:Cfg.RecordDirMode -eq 'Custom' -and $script:Cfg.RecordDir) {
        $d = $script:Cfg.RecordDir
        if ((-not (Test-Path -LiteralPath $d -PathType Container)) -and -not [string]::IsNullOrWhiteSpace($d)) {
            try { New-Item -ItemType Directory -Path $d -Force | Out-Null } catch { throw "Cannot create output directory '$d': $($_.Exception.Message)" }
        }
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { throw "Output directory does not exist: '$d'" }
    }
    else { $d = $PSScriptRoot }
    return $d
}

function Get-RecordFileName {
    param([string]$Ext)
    $dir = Get-RecordOutputDir
    $base = 'rec-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $candidate = Join-Path $dir "$base.$Ext"
    $i = 0
    while (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $i++
        $candidate = Join-Path $dir "$base-$i.$Ext"
    }
    return $candidate
}

# --- preset and arg building ---

function Get-FfmpegVideoPresetArgs {
    param([string]$Preset, [long]$BitrateBps, [int]$RecFps, [string]$RecSize)

    $enc = $script:EncoderCache
    $videoPresetArgs = switch ($Preset) {
        'Copy' { @('-c:v','copy') }
        'Balanced' { @('-c:v','libx264','-preset','veryfast','-crf','23') }
        'HighQuality' { @('-c:v','libx264','-preset','slow','-crf','18') }
        'StorageEfficient' { @('-c:v','libx265','-preset','fast','-crf','30') }
        default { @('-c:v','copy') }
    }

    if ($Preset -ne 'Copy') {
        if ($BitrateBps -gt 0) { $videoPresetArgs += @('-b:v', [string]$BitrateBps) }
        if ($RecFps -gt 0)     { $videoPresetArgs += @('-r', [string]$RecFps) }
        if ($RecSize)          { $videoPresetArgs += @('-vf', "scale=$RecSize") }
    }
    return $videoPresetArgs
}

function Get-ContainerCompatibilityMessage {
    param([string]$Container, [string]$VideoPreset, [string]$AudioMode)
    if ($Container -eq 'mp4') {
        if ($AudioMode -in @('Opus','Flac','Pcm')) { return "MP4 cannot carry $( $AudioMode ) audio; using AAC instead." }
        if ($VideoPreset -eq 'StorageEfficient') { return $null }  # h265 in mp4 is OK
    }
    return $null
}

function Get-FfmpegAudioArgs {
    param([string]$Mode, [int]$Kbps, [string]$Container)
    $m = $Mode
    if ($Container -eq 'mp4' -and $Mode -in @('Opus','Flac','Pcm')) { $m = 'Aac' }
    switch ($m) {
        'Copy' { return @('-c:a','copy') }
        'Aac'  { return @('-c:a','aac','-b:a',"${Kbps}k") }
        'Opus' { return @('-c:a','libopus','-b:a',"${Kbps}k") }
        'Flac' { return @('-c:a','flac') }
        'Pcm'  { return @('-c:a','pcm_s16le') }
        default { return @('-c:a','copy') }
    }
}

function Test-CustomArgs([string]$Text) {
    $tokens = @(ConvertFrom-CustomArgs $Text)
    $forbidden = @('-i','-map','-y','-f','-protocol_whitelist','-protocols','-input','-output','pipe:','tcp://','udp://','-listen')
    foreach ($t2 in $tokens) {
        foreach ($f in $forbidden) {
            if ($t2.StartsWith($f, [System.StringComparison]::OrdinalIgnoreCase)) {
                return @{ Ok = $false; Reason = "Argument '$t2' is application-managed here." }
            }
        }
    }
    return @{ Ok = $true }
}

function ConvertFrom-CustomArgs([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $out = @()
    # A token is any mix of quoted and unquoted segments with no whitespace
    # between them (so title="a b" stays ONE argument); quotes are stripped
    # after the split.
    foreach ($m in [regex]::Matches($Text, '(?:[^\s"'']+|"[^"]*"|''[^'']*'')+')) {
        $v = $m.Value -replace '"([^"]*)"', '$1' -replace "'([^']*)'", '$1'
        if ($v) { $out += $v }
    }
    return $out
}

# --- recording lifecycle ---

function Get-CapturePairNameFromRender {
    # Given the currently picked render target, find THIS phone-cable device's
    # companion capture endpoint name (e.g. "CABLE Output (VB-Audio Virtual Cable)").
    param()
    $renderId = $script:Cfg.AudioTargetId
    if (-not $renderId) { return $null }

    try {
        $instValue = $null
        $renderRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
        $guidPart = $renderId -replace '^.*\.\{', '' -replace '\}\\.?\s*$', '' -replace '\}$', ''
        foreach ($key in (Get-ChildItem -LiteralPath $renderRoot)) {
            if ('{0.0.0.00000000}.' + $key.PSChildName -ne $renderId) { continue }
            $props = Get-ItemProperty -LiteralPath (Join-Path $key.PSPath 'Properties')
            $instValue = $props.PSObject.Properties['{b3f8fa53-0004-438e-9003-51a46e139bfc},2'].Value
            $renderName = $props.PSObject.Properties['{a45c254e-df1c-4efd-8020-67d146a850e0},2'].Value
            break
        }
        if (-not $instValue) { return $null }

        $captureRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture'
        foreach ($key in (Get-ChildItem -LiteralPath $captureRoot)) {
            $st = (Get-ItemProperty -LiteralPath $key.PSPath).DeviceState
            if (($st -band 1) -eq 0) { continue }
            $props = Get-ItemProperty -LiteralPath (Join-Path $key.PSPath 'Properties')
            $ci = $props.PSObject.Properties['{b3f8fa53-0004-438e-9003-51a46e139bfc},2'].Value
            if ($ci -eq $instValue) {
                $desc = $props.PSObject.Properties['{a45c254e-df1c-4efd-8020-67d146a850e0},2'].Value
                $iface = $props.PSObject.Properties['{b3f8fa53-0004-438e-9003-51a46e139bfc},6'].Value
                $name = if ($desc) { $desc } elseif ($iface) { $iface } else { 'unknown' }
                if ($iface) { $name = "$desc ($iface)" }
                return $name
            }
        }
    } catch {
        Log "capture-endpoint pairing lookup failed: $($_.Exception.Message)"
    }

    return $null
}

function Start-Recording {
    Assert-TransitionAllowed
    if (Test-RecordingActive) { Write-Host 'Recording is already active.' -ForegroundColor Yellow; return }

    # Enter (or reuse) the logical recording session. It survives physical
    # finalizations caused by Mode-2 disconnect + reconnect cycles.
    Enter-LogicalRecordingSession

    $streams = @(Get-RecordEffectiveStreams)
    if ($streams.Count -eq 0) {
        Write-Host 'Recording target Off (or not supported by this mode); nothing to record.' -ForegroundColor DarkGray
        return
    }

    $ff = Assert-FFmpegOrPrompt
    if (-not $ff) { Write-Host 'Recording cancelled (FFmpeg not available).' -ForegroundColor Yellow; return }

    $ffprobe = Resolve-FFprobe
    [void](Get-FfmpegEncoders)   # fill cache for validation

    $container = [string]$script:Cfg.RecordContainer
    $outFile = Get-RecordFileName -Ext $container
    $compatMsg = Get-ContainerCompatibilityMessage -Container $container -VideoPreset ([string]$script:Cfg.RecordVideoPreset) -AudioMode ([string]$script:Cfg.RecordAudioMode)
    if ($compatMsg) { Write-Host $compatMsg -ForegroundColor DarkYellow }

    $custom = @(ConvertFrom-CustomArgs ([string]$script:Cfg.RecordCustomArgs))
    if ($custom.Count -gt 0) {
        $check = Test-CustomArgs ([string]$script:Cfg.RecordCustomArgs)
        if (-not $check.Ok) { Write-Host "Custom args rejected: $($check.Reason)" -ForegroundColor Red; return }
    }

    # --- build input plan per stream ---
    $needVideo = $streams -contains 'Video'
    $needAudio = $streams -contains 'Audio'

    $recVideoPort = $null
    $recAudioInputArgs = @()

        try {
            Ensure-RecordingProducers -Streams $streams
            # Disconnect policies (placeholder/split) only work with the watcher
            # up; a RecordOnly session has no Start-Camera to have started it.
            Start-DeviceWatcher

        if ($needVideo) {
            # relay the server video stream; ffmpeg reads from the relay; the
            # placeholder upstream port lets Mode-1 disconnects keep recording.
            $recVideoPort = Start-RecordRelay -ListenPort $script:VideoRelayPort -UpstreamPort $script:VideoServerPort -VideoPreamble -PlaceholderListenPort $script:VideoPlaceholderPort
            Start-Sleep -Milliseconds 400
        }

        $audioInputArgs = @()
        if ($needAudio) {
            if ($script:State.ProducerA -eq 'server') {
                $null = Start-RecordRelay -ListenPort $script:AudioRelayPort -UpstreamPort $script:AudioServerPort -PlaceholderListenPort $script:AudioPlaceholderPort
                $audioIn = "tcp://127.0.0.1:$($script:AudioRelayPort)"
                $audioInputArgs = @('-f','s16le','-ar','48000','-ac','2','-i',$audioIn)
                Start-Sleep -Milliseconds 300
            }
            else {
                # tap the live cable path (no producer switch for audio)
                $capName = Get-CapturePairNameFromRender
                if (-not $capName) { throw 'Could not find the capture endpoint paired with the selected audio output.' }
                # NOTE: no inner quotes; the argument is passed whole to ProcessStartInfo.
                $audioInputArgs = @('-f','dshow','-i',"audio=$capName")
            }
        }

        $argsList = @(
            '-hide_banner','-nostats','-loglevel','warning',
            '-fflags','+genpts','-use_wallclock_as_timestamps','1',
            '-analyzeduration','10000000','-probesize','20000000'
        )
        $inputs = 0
        if ($recVideoPort) { $argsList += @('-f','h264','-i',"tcp://127.0.0.1:$recVideoPort"); $inputs++ }
        if (@($audioInputArgs).Count -gt 0) { $argsList += $audioInputArgs; $inputs++ }

        $vpn = Get-FfmpegVideoPresetArgs -Preset ([string]$script:Cfg.RecordVideoPreset) -BitrateBps ([long]$script:Cfg.RecordVideoBitrateBps) -RecFps ([int]$script:Cfg.RecordFps) -RecSize ([string]$script:Cfg.RecordResolution)
        $apn = Get-FfmpegAudioArgs -Mode ([string]$script:Cfg.RecordAudioMode) -Kbps ([int]$script:Cfg.RecordAudioBitrateKbps) -Container $container

        $maps = @()
        if ($inputs -eq 2) { $maps = @('-map','0:v','-map','1:a') }
        elseif ($inputs -eq 1) {
            $maps = if ($needVideo) { @('-map','0:v') } else { @('-map','0:a') }
        }

        # -y is safe: Get-RecordFileName always produces a fresh non-colliding name.
        $argsList += $maps + $vpn + $apn + $custom + @('-y', $outFile)

        Log "ffmpeg start: $ff $($argsList -join ' ')"

        # PowerShell's Start-Process -ArgumentList flattens and re-parses at
        # spaces; use ProcessStartInfo.ArgumentList so every token stays one
        # exact argv entry (paths and dshow device names contain spaces).
        $ffmpegLog = $script:FfmpegLogFile

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ff
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardOutput = $true

        # exact argv token passthrough (no re-quoting/re-splitting)
        foreach ($arg in $argsList) { $psi.ArgumentList.Add([string]$arg) }

        # stderr drained to file by a pure-.NET thread (no PS/delegate crossing)
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi

        [void]$proc.Start()

        # drain stdout too (ffmpeg progress/stats) so the pipe never backs up
        $script:State.RecordingDrains = @(
            (New-Object ScrcpyCamHelper.StreamDrain($proc.StandardError.BaseStream, $ffmpegLog)),
            (New-Object ScrcpyCamHelper.StreamDrain($proc.StandardOutput.BaseStream, ($ffmpegLog -replace '\.log$', '.out.log')))
        )
        foreach ($d in $script:State.RecordingDrains) { $d.Start() }

        $script:State.Recording = [pscustomobject]@{
            State      = 'Starting'
            Pid        = [int]$proc.Id
            OutFile    = $outFile
            Target     = $streams -join '+'
            StartedAt  = Get-Date
            VideoPort  = $recVideoPort
            Proc       = $proc
            Ffprobe    = $ffprobe
            Container  = $container
            Error      = $null
        }
        [ScrcpyCamHelper.Win32]::RegisterExtraOwnedPid([uint32]$proc.Id)

        # confirm it actually started producing output (the stall watchdog is
        # pumped along the way, so a server that wedges before delivering its
        # first bytes gets restarted INSIDE this window instead of failing the
        # start)
        $deadline = (Get-Date).AddSeconds([int]$script:Const.FfmpegStartSec)
        while ((Get-Date) -lt $deadline) {
            if ($proc.HasExited) { break }
            if ((Test-Path -LiteralPath $outFile) -and ((Get-Item -LiteralPath $outFile).Length -gt 0)) { break }
            try { Update-RecordingHealth } catch { }
            Start-Sleep -Milliseconds ([int]$script:Const.FfmpegStartPollMs)
        }

        if ($proc.HasExited) {
            $script:State.Recording.State = 'Failed'
            $script:State.Recording.Error = "ffmpeg exited during startup (code $($proc.ExitCode))"
            Read-FFmpegStderrTail $proc
            throw "FFmpeg failed to start recording (exit $($proc.ExitCode)). See $($script:LogFile)."
        }

        if (-not ((Test-Path -LiteralPath $outFile) -and ((Get-Item -LiteralPath $outFile).Length -gt 0))) {
            $script:State.Recording.State = 'Failed'
            $script:State.Recording.Error = 'no output bytes after 25s'
            throw 'FFmpeg produced no output within the expected window.'
        }

        $script:State.Recording.State = 'Recording'
        Log "Recording started: $outFile (target=$($script:State.Recording.Target))"
        Write-Host ''
        Write-Host "RECORDING -> $outFile" -ForegroundColor Green
        Write-Host "Target: $($script:State.Recording.Target), container: $container"
        Write-Host 'Stop it with [G] Stop Recording (Session section of the main screen).' -ForegroundColor DarkGray
    }
    catch {
        Log "Start-Recording failed: $($_.Exception.Message)"
        Log "stack: $($_.ScriptStackTrace)"
        # never leave a half-started ffmpeg running: finalize-or-kill it
        try {
            $p = $script:State.Recording.Proc
            if ($p -and -not $p.HasExited) {
                try { $p.StandardInput.WriteLine('q'); $p.StandardInput.Flush() } catch { Log "ffmpeg 'q' write during failed-start cleanup: $($_.Exception.Message)" }
                if (-not $p.WaitForExit(8000)) { $p.Kill(); [void]$p.WaitForExit([int]$script:Const.FfmpegKillWaitMs) }
            }
        } catch { Log "failed-start ffmpeg teardown note: $($_.Exception.Message)" }
        try { [ScrcpyCamHelper.Win32]::UnregisterExtraOwnedPid([uint32]$script:State.Recording.Pid) } catch { Log "unregister ffmpeg PID note: $($_.Exception.Message)" }
        $script:State.Recording = $null
        throw "Failed to start recording: $($_.Exception.Message)"
    }
}

function Read-FFmpegStderrTail {
    param($Proc)
    try {
        if ($script:FfmpegLogFile -and (Test-Path -LiteralPath $script:FfmpegLogFile)) {
            $tail = Get-Content -LiteralPath $script:FfmpegLogFile -Tail 25 -ErrorAction SilentlyContinue
            if ($tail) { Log ("ffmpeg stderr tail:`n" + ($tail -join "`n")) }
        }
    } catch { Log "could not read ffmpeg stderr tail: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
# Producer switching between scrcpy.exe (normal live) and standalone server
# (recording-capable producers): BOTH recorded streams move to servers+relays
# in one restart - see Ensure-RecordingProducers, the single place that
# performs the switch. Single camera/mic capture owner at all times.
# ---------------------------------------------------------------------------

function Ensure-RecordingProducers {
    # Makes the capture infrastructure exist for the requested streams.
    # EVERY recorded stream is produced by the on-device scrcpy-server behind a
    # localhost relay: the recorder is then one consumer among several, and the
    # live leg (ffplay preview window / ffplay cable playback) is an independent
    # consumer that can stop without touching the recording. Anything still
    # produced by the scrcpy.exe client is moved over in ONE restart (two
    # separate restarts would double the preview blackout).
    param([Parameter(Mandatory)][string[]]$Streams)

    $needVideo = 'Video' -in $Streams
    $needAudio = 'Audio' -in $Streams

    $flipV = $needVideo -and ($script:State.ProducerV -ne 'server')
    $flipA = $needAudio -and ($script:State.ProducerA -ne 'server')

    if ($flipV) { $script:State.ProducerV = 'server' }
    if ($flipA) { $script:State.ProducerA = 'server' }
    if (($flipV -or $flipA) -and (Is-SessionRunning)) {
        Stop-Camera -Silent
        Start-Camera
    }

    if ($needVideo) {
        # servers+relays need State.ScrcpyExe/AdbExe/Serial even in RecordOnly:
        if (-not $script:State.Serial) {
            $sc = Resolve-Scrcpy
            $adb = Resolve-Adb -ScrcpyExe $sc
            $dev = Choose-Device -AdbExe $adb
            $script:State.ScrcpyExe = $sc
            $script:State.AdbExe = $adb
            $script:State.Serial = $dev.Serial
        }
        if (-not $script:State.VideoServerPid) {
            [void](Start-StandaloneServer -Kind 'video' -AdbExe $script:State.AdbExe -Serial $script:State.Serial)
            $script:State.VideoServerPid = $true
        }
    }

    if ($needAudio -and $script:State.ProducerA -eq 'server') {
        if (-not $script:State.Serial) {
            $sc = Resolve-Scrcpy
            $adb = Resolve-Adb -ScrcpyExe $sc
            $dev = Choose-Device -AdbExe $adb
            $script:State.ScrcpyExe = $sc
            $script:State.AdbExe = $adb
            $script:State.Serial = $dev.Serial
        }
        if (-not $script:State.AudioServerPid) {
            [void](Start-StandaloneServer -Kind 'audio' -AdbExe $script:State.AdbExe -Serial $script:State.Serial)
            $script:State.AudioServerPid = $true
        }
    }
}

function Start-FfplayLiveWindow {
    # renders the relayed video (and may be routed to the cable for audio).
    # Same window title as the scrcpy path, so OBS never re-learns anything.
    param([string]$InputUrl, [switch]$AudioOnly)

    $ffplayCmds = @(Get-Command ffplay.exe -CommandType Application -ErrorAction SilentlyContinue)
    $play = if ($ffplayCmds.Count -gt 0) {
        [string]$ffplayCmds[0].Source
    } elseif ($script:Cfg.FFmpegPath) {
        $beside = Join-Path (Split-Path -Parent $script:Cfg.FFmpegPath) 'ffplay.exe'
        if (Test-Path -LiteralPath $beside -PathType Leaf) { $beside } else { $null }
    } else { $null }

    if (-not $play) {
        $ff = Resolve-FFmpeg
        if ($ff) {
            $beside = Join-Path (Split-Path -Parent $ff) 'ffplay.exe'
            if (Test-Path -LiteralPath $beside -PathType Leaf) { $play = $beside }
        }
    }
    if (-not $play) { throw 'ffplay.exe was not found next to ffmpeg.exe or on PATH.' }

    $aff = if ($AudioOnly) {
        @()
    } else {
        @('-hide_banner','-loglevel','error','-f','h264','-fflags','nobuffer','-flags','low_delay')
    }

    $wg = @(
        '-window_title', [string]$script:Cfg.WindowTitle,
        '-left','0','-top','0',
        '-x',[string]$script:Cfg.Width,
        '-y',[string]$script:Cfg.Height,
        '-noborder'
    )

    $ffArgs = @()
    if (-not $AudioOnly) { $ffArgs += $aff }
    if ($AudioOnly) {
        $ffArgs += @('-hide_banner','-loglevel','error','-vn','-f','s16le','-ar','48000','-ac','2')
    }
    $ffArgs += @('-i', $InputUrl)
    if (-not $AudioOnly) { $ffArgs += $wg }

    Log "ffplay start: $play $($ffArgs -join ' ')"

    # exact argv token passthrough (the window title contains spaces; a plain
    # Start-Process -ArgumentList join would re-split them)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $play
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    foreach ($arg in $ffArgs) { $psi.ArgumentList.Add([string]$arg) }
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()

    # drain ffplay output so its pipes never back up (and diagnostics exist).
    # Separate files per stream AND per process: StreamDrain uses FileMode.
    # Create, so two drains sharing one path would truncate each other's log.
    $ffplayLogBase = Join-Path $env:TEMP ('scrcpy-camera-helper.ffplay-{0}' -f $proc.Id)
    $script:State.FfplayDrains = @(
        (New-Object ScrcpyCamHelper.StreamDrain($proc.StandardError.BaseStream, "$ffplayLogBase.err.log")),
        (New-Object ScrcpyCamHelper.StreamDrain($proc.StandardOutput.BaseStream, "$ffplayLogBase.out.log"))
    )
    foreach ($d in $script:State.FfplayDrains) { $d.Start() }

    $script:State.Owned += [int]$proc.Id
    [ScrcpyCamHelper.Win32]::RegisterExtraOwnedPid([uint32]$proc.Id)

    if ($AudioOnly) {
        # no video window ever appears; just confirm the process is alive
        $deadline = (Get-Date).AddMilliseconds([int]$script:Const.WindowWaitMs)
        while ((Get-Date) -lt $deadline) {
            if ($proc.HasExited) { throw "ffplay (audio) exited early (code $($proc.ExitCode))" }
            Start-Sleep -Milliseconds ([int]$script:Const.WindowPollMs)
            return [pscustomobject]@{ Pid = [int]$proc.Id; Hwnd = [IntPtr]::Zero; Proc = $proc }
        }
        return [pscustomobject]@{ Pid = [int]$proc.Id; Hwnd = [IntPtr]::Zero; Proc = $proc }
    }

    # park it once its window appears
    $deadline = (Get-Date).AddMilliseconds([int]$script:Const.FfplayWindowWaitMs)
    $HWND = [IntPtr]::Zero
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds ([int]$script:Const.WindowPollMs)
        $otherPid = [uint32]0
        $h = [ScrcpyCamHelper.Win32]::FindVisibleWindowByTitle([string]$script:Cfg.WindowTitle, [ref]$otherPid)
        if ($h -ne [IntPtr]::Zero -and $otherPid -eq [uint32]$proc.Id) {
            $HWND = $h; break
        }

        if ($proc.HasExited) {
            Log "ffplay exited early (code $($proc.ExitCode))"
            break
        }
    }

    if ($HWND -eq [IntPtr]::Zero) {
        # A late preview must never kill a recording: the relay/ffmpeg pair is
        # already delivering; ffplay sometimes surfaces its window after the
        # first IDR cadence. Warn and keep going instead of failing the start.
        Log 'ffplay window did not appear within the deadline; recording continues, preview will pop up when ready'
        Write-Host 'NOTE: the live preview is taking longer than usual to appear.' -ForegroundColor Yellow
        Write-Host 'The session and any recording keep running - the window will pop up when ready.' -ForegroundColor Yellow
        return [pscustomobject]@{ Pid = [int]$proc.Id; Hwnd = [IntPtr]::Zero; Proc = $proc }
    }

    $script:State.FFplayPid = [int]$proc.Id
    $script:State.FFplayHwnd = $HWND

    Apply-Parking -Hwnd $HWND -Mode $script:Cfg.ParkingMode

    $script:State.Hwnd = $HWND

    return [pscustomobject]@{ Pid = $script:State.FFplayPid; Hwnd = $HWND; Proc = $proc }
}

# ---------------------------------------------------------------------------
# Logical recording session layer. Mode1 and Mode2 differ only in how a
# disconnect behaves; everything else reuses the same physical file machinery.
# ---------------------------------------------------------------------------

function Start-LogicalSession {
    if ($script:LogicalSession -and $script:LogicalSession.Active) { return }
    $script:LogicalSession = [pscustomobject]@{
        Active         = $true
        StartedAt      = Get-Date
        Files          = New-Object System.Collections.Generic.List[string]
        PlaceholderIntervals = New-Object System.Collections.Generic.List[object]
        PolicyAtStart  = [string]$script:Cfg.DisconnectPolicy
        Container      = [string]$script:Cfg.RecordContainer
        Outcome        = $null
    }
    Log "logical recording session opened (policy=$($script:LogicalSession.PolicyAtStart))"
}

function Add-PhysicalFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not $script:LogicalSession -or -not $script:LogicalSession.Active) { Start-LogicalSession }
    if ($Path -and ($script:LogicalSession.Files -notcontains $Path)) {
        $script:LogicalSession.Files.Add($Path)
    }
}

function Stop-Recording {
    param([switch]$Silent)

    $rec = $script:State.Recording
    if (-not $rec) {
        if (-not $Silent) { Write-Host 'Not recording.' }
        return
    }

    $preview = $rec
    $script:State.Recording.State = 'Stopping'

    # signal FFmpeg gracefully first (stdin 'q' -> finalize + exit). The stall
    # watchdog is pumped while we wait: if ffmpeg is stuck behind starved
    # socket reads (wedged producer), restarting that producer lets bytes flow
    # again, after which ffmpeg honors the queued 'q' and still FINALIZES the
    # file - instead of being force-killed into a truncated, duration-less one.
    try {
        if ($rec.Proc -and -not $rec.Proc.HasExited) {
            try { $rec.Proc.StandardInput.WriteLine('q'); $rec.Proc.StandardInput.Flush() } catch { Log "ffmpeg stdin 'q' write failed: $($_.Exception.Message)" }
            $quitDeadline = (Get-Date).AddMilliseconds([int]$script:Const.FfmpegQuitWaitMs)
            while (-not $rec.Proc.WaitForExit(500)) {
                if ((Get-Date) -ge $quitDeadline) { break }
                try { Update-RecordingHealth } catch { }
            }
            if (-not $rec.Proc.HasExited) {
                $rec.Proc.Kill()
                [void]$rec.Proc.WaitForExit([int]$script:Const.FfmpegKillWaitMs)
            }
        }
    } catch { Log "graceful stop issue: $($_.Exception.Message)" }

    $exitCode = $rec.Proc.ExitCode
    $script:State.Recording = $null
    Add-PhysicalFile -Path $preview.OutFile

    $msg = "recording stopped ($([string]$preview.Target)) -> $($preview.OutFile)"
    if ($exitCode -ge 0) { $msg += " [ffmpeg exit $exitCode]" }
    Log $msg

    # integrity check with ffprobe when present
    if ($preview.Ffprobe -and (Test-Path -LiteralPath $preview.OutFile -PathType Leaf)) {
        try {
            $info = & $preview.Ffprobe -v error -show_entries format=duration,size,format_name -show_entries stream=index,codec_name,codec_type,width,height,sample_rate -of default=nw=1 $preview.OutFile 2>&1
            Log ("probe: " + ($info -join '; '))
            # A file whose container was never finalized (forced kill) probes
            # with duration=N/A - surface that loudly instead of calling it OK.
            $durText = [string](($info | Where-Object { $_ -match '^duration=' } | Select-Object -First 1) -replace '^duration=', '')
            $durVal = 0.0
            $okDur = [double]::TryParse($durText, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$durVal)
            if (-not $okDur -or $durVal -le 0) {
                Log "WARNING: probe reports no valid duration (duration='$durText'); the file was likely NOT finalized cleanly: $($preview.OutFile)"
                if (-not $Silent) { Write-Host 'WARNING: ffprobe shows no valid duration - the file may be truncated.' -ForegroundColor Yellow }
            }
            elseif (-not $Silent) { Write-Host "VERIFY OK: $([IO.Path]::GetFileName($preview.OutFile))" -ForegroundColor Green; ($info -join "`n") | Write-Host }
        } catch { Log "ffprobe failed: $($_.Exception.Message)" }
    }

    if (-not $Silent) { Write-Host 'Recording stopped and finalized.' -ForegroundColor Cyan }
}

function Get-DeviceCapabilities {
    param(
        [Parameter(Mandatory)][string]$ScrcpyExe,
        [Parameter(Mandatory)][string]$Serial
    )

    # cache key: device serial + scrcpy version + codec
    $version = Get-ScrcpyVersion -ScrcpyExe $ScrcpyExe
    $key = "$Serial|$version"
    if ($script:CapCache -and $script:CapCache.Key -eq $key) {
        return $script:CapCache.Value
    }

    $caps = [pscustomobject]@{
        Key          = $key
        Serial       = $Serial
        Model        = ''
        Cameras      = @()
        Encoders     = @()   # video encoders
        Bitrate      = $null
        DiscoveredAt = Get-Date
    }

    # ---- cameras (also carries the per-camera fps set + max size)
    $camOut = & $ScrcpyExe --serial $Serial --list-cameras 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("scrcpy --list-cameras failed: {0}" -f ($camOut -join "`n")) }

    foreach ($lineObj in $camOut) {
        $line = [string]$lineObj

        if ($line -match 'Device:\s*(\[[^\]]+\])?\s*(.+?)\s*\(Android\s*([^)]*)\)') {
            # e.g. "[Brand] Brand MODEL (Android NN)" -> strip the bracketed dup
            $caps.Model = (($Matches[2] -replace '[][]', '') -replace '\s+', ' ').Trim() + " (Android $($Matches[3]))"
        }

        if ($line -match '--camera-id=(\d+)\s+\((\w+),\s*(\d+x\d+),\s*fps=\{([^}]*)\},\s*zoom-range=\[([^\]]*)\]\)') {
            $fpsSet = @($Matches[4] -split ',\s*' | ForEach-Object { [int]$_ })
            $caps.Cameras += [pscustomobject]@{
                Id        = [int]$Matches[1]
                Facing    = $Matches[2]
                MaxSize   = $Matches[3]
                FpsSet    = $fpsSet
                ZoomRange = $Matches[5]
                Sizes     = @()
                HighSpeed = @()   # entries: @{ Size; FpsSet }
            }
            Log "Discovered camera id=$($Matches[1]) facing=$($Matches[2]) max=$($Matches[3]) fps={$($fpsSet -join ',')}"
        }
    }

    if ($caps.Cameras.Count -eq 0) {
        throw @"
No cameras were parsed from 'scrcpy --list-cameras'.
This usually means the phone has no camera2 API access for this user - or the
scrcpy output format changed. Raw output was:
$($camOut -join "`n")
"@
    }

    # ---- sizes + high-speed section per camera
    $sizeOut = & $ScrcpyExe --serial $Serial --list-camera-sizes 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("scrcpy --list-camera-sizes failed: {0}" -f ($sizeOut -join "`n")) }

    $curCam = $null
    $inHighSpeed = $false
    foreach ($lineObj in $sizeOut) {
        $line = [string]$lineObj

        if ($line -match '--camera-id=(\d+)') {
            $camId = [int]$Matches[1]
            $curCam = $caps.Cameras | Where-Object { $_.Id -eq $camId } | Select-Object -First 1
            $inHighSpeed = $false
            continue
        }

        if ($line -match 'High speed capture') {
            $inHighSpeed = $true
            continue
        }

        if ($curCam -and $line -match '^\s+-\s+(\d+x\d+)(?:\s+\(fps=\{([^}]*)\}\))?\s*$') {
            $size = $Matches[1]
            if ($inHighSpeed) {
                $hsFps = @()
                if ($Matches[2]) { $hsFps = @($Matches[2] -split ',\s*' | ForEach-Object { [int]$_ }) }
                $curCam.HighSpeed += [pscustomobject]@{ Size = $size; FpsSet = $hsFps }
            }
            else {
                $curCam.Sizes += $size
            }
        }
    }

    # Guard against silent parser drift: we must have found at least one
    # usable size somewhere, otherwise every later picker would be empty.
    $anySizes = 0
    foreach ($c in $caps.Cameras) { $anySizes += $c.Sizes.Count + $c.HighSpeed.Count }
    if ($anySizes -eq 0) {
        throw @"
No camera sizes were parsed from 'scrcpy --list-camera-sizes'.
If the phone was reachable, the scrcpy output format likely changed. Raw output:
$($sizeOut -join "`n")
"@
    }

    # ---- video encoders
    $encOut = & $ScrcpyExe --serial $Serial --list-encoders 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("scrcpy --list-encoders failed: {0}" -f ($encOut -join "`n")) }

    $inVideoEncoders = $false
    foreach ($lineObj in $encOut) {
        $line = [string]$lineObj

        if ($line -match 'List of video encoders') { $inVideoEncoders = $true; continue }
        if ($line -match 'List of audio encoders') { $inVideoEncoders = $false; continue }

        if ($inVideoEncoders -and $line -match '--video-codec=(\w+)\s+--video-encoder=(\S+)\s+(.*)$') {
            $caps.Encoders += [pscustomobject]@{
                Codec   = $Matches[1]
                Name    = $Matches[2]
                Tags    = $Matches[3].Trim()
            }
        }
    }

    if ($caps.Encoders.Count -eq 0) {
        # Non-fatal on purpose: encoder data gates only the bitrate UI, and
        # some devices bury it. But note it so a scrcpy format change is
        # diagnosable from the log instead of looking like a dead feature.
        Log 'no video encoders parsed from --list-encoders (output format change?); encoder-derived bitrate limits may be unavailable'
    }

    $script:CapCache = [pscustomobject]@{ Key = $key; Value = $caps }
    return $caps
}

function Get-EncoderDeclarationXml {
    # Reads the on-device codec declaration data Android itself parses into
    # MediaCodecInfo/CodecCapabilities - via "adb shell cat", read-only, no
    # root, nothing installed, nothing left behind.
    param(
        [Parameter(Mandatory)][string]$AdbExe,
        [Parameter(Mandatory)][string]$Serial
    )

    $files = @(& $AdbExe shell 'ls /vendor/etc/media_codecs*.xml /system/etc/media_codecs*.xml 2>/dev/null' 2>$null)
    $xml = ''

    foreach ($fObj in $files) {
        $f = [string]$fObj -replace '\s+$', ''
        if ($f -notmatch '\.xml$') { continue }
        $chunk = & $AdbExe -s $Serial shell "cat `"$f`"" 2>$null
        if ($chunk) { $xml += "`n" + ($chunk -join "`n") }
    }

    return $xml
}

function Get-DefaultEncoderFromXml {
    param([string]$Xml, [string]$MimeType)

    # First MediaCodec encoder block for the type, in declaration order -
    # that is what Android's MediaCodecList (and therefore scrcpy's
    # createEncoderByType default) selects. Decoder blocks share the same
    # tag/type shape, so the scan is scoped to the <Encoders> section first.
    $scope = [string]$Xml
    $section = [regex]::Match($Xml, '(?s)<Encoders[^>]*>(.*?)</Encoders>', 'IgnoreCase')
    if ($section.Success) { $scope = $section.Groups[1].Value }

    $matchesList = [regex]::Matches(
        $scope,
        '(?s)<MediaCodec\s+name="([^"]+)"\s+type="([^"]+)"[^>]*>(.*?)</MediaCodec>',
        'IgnoreCase')

    foreach ($m in $matchesList) {
        if ($m.Groups[2].Value -ne $MimeType) { continue }
        $body = $m.Groups[3].Value
        $name = $m.Groups[1].Value
        $alias = $null
        if ($body -match '<Alias\s+name="([^"]+)"') { $alias = $Matches[1] }
        return [pscustomobject]@{ Name = $name; Alias = $alias }
    }

    return $null
}

function Get-EncoderBitrateRange {
    param(
        [string]$Xml,
        [Parameter(Mandatory)][string]$EncoderName,
        [string]$Alias,
        [Parameter(Mandatory)][string]$MimeType
    )

    $names = @($EncoderName)
    if ($Alias) { $names += $Alias }

    $allMatches = [regex]::Matches(
        $Xml,
        '(?s)<MediaCodec\s+name="([^"]+)"\s+type="([^"]+)"[^>]*>(.*?)</MediaCodec>',
        'IgnoreCase')

    foreach ($m in $allMatches) {
        $name = $m.Groups[1].Value
        $type = $m.Groups[2].Value
        if ($type -ne $MimeType) { continue }
        if ($names -notcontains $name) { continue }

        $body = $m.Groups[3].Value
        if ($body -match '<Limit\s+name="bitrate"\s+range="(\d+)-(\d+)"') {
            return [pscustomobject]@{
                MinBps = [long]$Matches[1]
                MaxBps = [long]$Matches[2]
            }
        }
    }

    return $null
}

function Resolve-EncoderCapabilities {
    param(
        [Parameter(Mandatory)][string]$AdbExe,
        [Parameter(Mandatory)][string]$Serial,
        [Parameter(Mandatory)]$Caps   # output of Get-DeviceCapabilities
    )

    $mime = 'video/avc'   # we use scrcpy's default video codec (H.264)

    $xml = Get-EncoderDeclarationXml -AdbExe $AdbExe -Serial $Serial

    $defaultInfo = $null
    if ($xml) {
        $defaultInfo = Get-DefaultEncoderFromXml -Xml $xml -MimeType $mime
    }

    if (-not $defaultInfo) {
        # fallback: first hardware/vendor encoder of the codec from scrcpy
        $defaultInfo = [pscustomobject]@{ Name = $null; Alias = $null }
        $hw = @($Caps.Encoders | Where-Object { $_.Codec -eq 'h264' -and $_.Tags -match 'hw' } | Select-Object -First 1)
        if ($hw) { $defaultInfo.Name = $hw[0].Name }
    }

    if (-not $defaultInfo.Name) {
        return [pscustomobject]@{
            Available = $false
            Codec     = 'h264'
            MimeType  = $mime
            Reason    = 'Could not determine the default h264 encoder.'
        }
    }

    $range = $null
    if ($xml) {
        $range = Get-EncoderBitrateRange -Xml $xml -EncoderName $defaultInfo.Name -Alias $defaultInfo.Alias -MimeType $mime
    }

    return [pscustomobject]@{
        Available   = $null -ne $range
        Codec       = 'h264'
        MimeType    = $mime
        EncoderName = $defaultInfo.Name
        Alias       = $defaultInfo.Alias
        MinBps      = if ($range) { $range.MinBps } else { $null }
        MaxBps      = if ($range) { $range.MaxBps } else { $null }
        ParserMaxBps= $script:Const.ScrcpyParserMaxBps
        Source      = if ($range) { 'device codec declarations (via adb)' } else { $null }
        Reason      = if ($range) { $null } else { 'Bitrate limits were not declared for this encoder.' }
    }
}

function Get-BitrateUiStep {
    param([long]$MinBps, [long]$MaxBps)
    # A UI navigation increment, NOT a hardware step claim.
    $span = $MaxBps - $MinBps
    if ($span -le 10000000) { return [long]100000 }        # 0.1 Mbps
    if ($span -le 50000000) { return [long]500000 }        # 0.5 Mbps
    if ($span -le 200000000) { return [long]1000000 }      # 1.0 Mbps
    return [long]2000000                                   # very large spans
}

function Get-CurrentCameraId {
    # The camera scrcpy will actually use: explicit choice if made, else the
    # first device-reported "back" camera (scrcpy --camera-facing=back default).
    if ($null -ne $script:Cfg.CameraId) { return [int]$script:Cfg.CameraId }
    if ($script:CapCache) {
        $backCam = @($script:CapCache.Value.Cameras | Where-Object { $_.Facing -eq 'back' } | Select-Object -First 1)
        if ($backCam.Count -gt 0) { return [int]$backCam[0].Id }
    }
    return $null
}

function Get-CameraById {
    param([Nullable[int]]$Id, $Caps)
    if (-not $Caps) { return $null }
    foreach ($cam in $Caps.Cameras) {
        if ($null -ne $Id -and $cam.Id -eq $Id) { return $cam }
    }
    return $null
}

function Get-HighSpeedModeForSize {
    param([Nullable[int]]$CameraId, [string]$Size)
    if (-not $script:CapCache) { return $null }
    $cam = Get-CameraById -Id $CameraId -Caps $script:CapCache.Value
    if (-not $cam) { return $null }
    foreach ($hs in $cam.HighSpeed) {
        if ($hs.Size -eq $Size) { return $hs }
    }
    return $null
}

function Invoke-CameraConfigChange {    # Applies a camera config change; restarts the scrcpy session if a camera
    # mode is live; rolls back to the previous value on runtime failure.
    param(
        [Parameter(Mandatory)][string]$What,
        [Parameter(Mandatory)][scriptblock]$ApplyNewValue,
        [Parameter(Mandatory)][scriptblock]$RestoreOldValue
    )

    Assert-TransitionAllowed

    # The camera is single-capture: while a recording owns it (via its server
    # producer), changing camera settings would restart that producer mid-file.
    if (Test-RecordingActive) {
        Write-Host "A recording is running - $What is locked until you stop it ([G] or [2])." -ForegroundColor Yellow
        return
    }

    & $ApplyNewValue
    Save-Settings
    Log "Camera config changed: $What"

    if ((Is-SessionRunning) -and (Test-ModeVideo)) {
        try {
            Invoke-SessionRestart -Reason "$What change"
        }
        catch {
            Write-Host ''
            Write-Host "The camera rejected the new $What setting at runtime:" -ForegroundColor Red
            Write-Host "  $($_.Exception.Message)" -ForegroundColor DarkGray
            Write-Host "Restoring the previous $What and restarting..." -ForegroundColor Yellow
            Log "Runtime rejection of $What ($($_.Exception.Message)) - rolling back"
            & $RestoreOldValue
            Save-Settings
            try {
                Set-TransitionState 'Switching'
                Stop-Camera -Silent
                Start-Camera
                Set-TransitionState 'Running'
                Write-Host 'Restored the previous working configuration.' -ForegroundColor Green
            }
            catch {
                Set-TransitionState 'Failed'
                Write-Host "Could not restore either configuration: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host 'State: Failed. Use [2] Stop then [1] Start to recover.' -ForegroundColor Yellow
            }
        }
    }
    elseif (-not (Test-ModeVideo) -and (Is-SessionRunning)) {
        Write-Host 'Saved - applies the next time a camera mode is started.' -ForegroundColor DarkGray
    }
    else {
        Write-Host 'Saved - applies at next start.' -ForegroundColor DarkGray
    }
}

function Show-CameraPicker {
    param([Parameter(Mandatory)]$Caps)

    Write-Host ''
    Write-Host 'Camera selection:' -ForegroundColor Yellow
    Write-Host "  [D] Default (Back camera, auto = scrcpy --camera-facing=back)$(if ($null -eq $script:Cfg.CameraId) { '   <== current' } else { '' })"
    for ($i = 0; $i -lt $Caps.Cameras.Count; $i++) {
        $cam = $Caps.Cameras[$i]
        $mark = ''
        if ($null -ne $script:Cfg.CameraId -and [int]$script:Cfg.CameraId -eq $cam.Id) { $mark = '   <== current' }
        $def = if ($cam.Facing -eq 'back' -and $null -eq $script:Cfg.CameraId) { ' [Default]' } else { '' }
        Write-Host ("  [{0}] Camera {1} - {2}   ({3}, fps {4}){5}{6}" -f ($i + 1), $cam.Id, $cam.Facing, $cam.MaxSize, ('{' + ($cam.FpsSet -join ', ') + '}'), $def, $mark)
    }
    Write-Host ''
    Write-Host 'Type a number (or D), then press Enter. Blank Enter keeps the current selection.' -ForegroundColor DarkGray

    $answer = (Read-Host 'Camera').Trim()
    if ($answer -eq '') { return $false }

    if ($answer -eq 'D') {
        $old = $script:Cfg.CameraId
        Invoke-CameraConfigChange -What 'Camera' -ApplyNewValue { $script:Cfg.CameraId = $null } -RestoreOldValue { $script:Cfg.CameraId = $old }
        return $true
    }

    $n = 0
    if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $Caps.Cameras.Count) {
        $cam = $Caps.Cameras[$n - 1]
        $oldCam = $script:Cfg.CameraId
        $oldSize = $script:Cfg.CameraSize
        $oldFps = $script:Cfg.Fps

        Invoke-CameraConfigChange -What "Camera -> id $($cam.Id)" -ApplyNewValue {
            $script:Cfg.CameraId = [int]$cam.Id

            # revalidate resolution + fps against the newly selected camera
            if ($cam.Sizes.Count -gt 0 -and ($script:Cfg.CameraSize -notin @($cam.Sizes))) {
                $newSize = if ($script:DefaultCameraSize -in @($cam.Sizes)) { $script:DefaultCameraSize } else { $cam.Sizes[0] }
                Write-Host "Size $($script:Cfg.CameraSize) not available on this camera; using $newSize." -ForegroundColor Yellow
                $script:Cfg.CameraSize = $newSize
            }

            # fps not in normal set must exist in hs map for current size
            if ($script:Cfg.Fps) {
                $fps = [int]$script:Cfg.Fps
                $hs = Get-HighSpeedModeForSize -CameraId $cam.Id -Size ([string]$script:Cfg.CameraSize)
                $allowed = @($cam.FpsSet) + $(if ($hs) { @($hs.FpsSet) } else { @() })
                if ($fps -notin $allowed) {
                    Write-Host "FPS $fps not valid on camera $($cam.Id); reverting to Android default." -ForegroundColor Yellow
                    $script:Cfg.Fps = $null
                }
            }
        } -RestoreOldValue {
            $script:Cfg.CameraId = $oldCam
            $script:Cfg.CameraSize = $oldSize
            $script:Cfg.Fps = $oldFps
        }
        return $true
    }

    Write-Host 'Invalid selection.' -ForegroundColor Yellow
    return $false
}

function Show-ResolutionPicker {
    param([Parameter(Mandatory)]$Caps)

    $camId = Get-CurrentCameraId
    $cam = Get-CameraById -Id $camId -Caps $Caps
    if (-not $cam) { throw 'Camera capabilities unavailable.' }
    if ($cam.Sizes.Count -eq 0) { throw 'No sizes were reported for this camera.' }

    Write-Host ''
    Write-Host "Resolution (camera $($cam.Id) - $($cam.Facing), $($cam.Sizes.Count) device-reported sizes):" -ForegroundColor Yellow

    for ($i = 0; $i -lt $cam.Sizes.Count; $i++) {
        $s = $cam.Sizes[$i]
        $marks = @()
        if ($s -eq $script:DefaultCameraSize) { $marks += '[Default]' }
        if ($s -eq $script:Cfg.CameraSize) { $marks += '<== current' }
        Write-Host ("  [{0}] {1} {2}" -f ($i + 1), $s, ($marks -join ' '))
    }
    Write-Host ''
    Write-Host 'Type a number, then press Enter. Blank Enter keeps the current selection.' -ForegroundColor DarkGray

    $answer = (Read-Host 'Resolution').Trim()
    if ($answer -eq '') { return }

    $n = 0
    if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $cam.Sizes.Count) {
        $newSize = [string]$cam.Sizes[$n - 1]
        if ($newSize -eq $script:Cfg.CameraSize) { return }
        $old = $script:Cfg.CameraSize
        $oldFps = $script:Cfg.Fps

        Invoke-CameraConfigChange -What "Resolution -> $newSize" -ApplyNewValue {
            $script:Cfg.CameraSize = $newSize

            # fps revalidation against the new size (high-speed window)
            if ($script:Cfg.Fps) {
                $fps = [int]$script:Cfg.Fps
                $allowed = @($cam.FpsSet)
                $hs = Get-HighSpeedModeForSize -CameraId $cam.Id -Size $newSize
                if ($hs) { $allowed = @($allowed + $hs.FpsSet) }
                if ($fps -notin $allowed) {
                    Write-Host "FPS $fps is not supported at $newSize - resetting to Android default." -ForegroundColor Yellow
                    $script:Cfg.Fps = $null
                }
            }
        } -RestoreOldValue {
            $script:Cfg.CameraSize = $old
            $script:Cfg.Fps = $oldFps
        }
        return
    }

    Write-Host 'Invalid selection.' -ForegroundColor Yellow
}

function Show-FpsPicker {
    param([Parameter(Mandatory)]$Caps)

    $camId = Get-CurrentCameraId
    $cam = Get-CameraById -Id $camId -Caps $Caps
    if (-not $cam) { throw 'Camera capabilities unavailable.' }

    $defaultFps = 30   # scrcpy camera.md: camera is captured at Android's default (30 fps)

    $choices = @()
    $choices += [pscustomobject]@{ Fps = $null; Label = "Android Default (30 FPS)"; IsDefault = $true }

    foreach ($f in $cam.FpsSet) {
        $choices += [pscustomobject]@{ Fps = $f; Label = "$f FPS"; IsDefault = $false }
    }

    # high-speed fps only when current size supports it (Android constraint)
    $hs = Get-HighSpeedModeForSize -CameraId $camId -Size ([string]$script:Cfg.CameraSize)
    if ($hs) {
        foreach ($f in $hs.FpsSet) {
            $choices += [pscustomobject]@{ Fps = $f; Label = "$f FPS (high-speed)"; IsDefault = $false }
        }
    }

    Write-Host ''
    Write-Host "Frame rate (camera $($cam.Id)):" -ForegroundColor Yellow
    for ($i = 0; $i -lt $choices.Count; $i++) {
        $c = $choices[$i]
        $marks = @()
        if ($c.IsDefault) { $marks += '[Default]' }
        if (($null -eq $script:Cfg.Fps -and $null -eq $c.Fps) -or
            ($null -ne $script:Cfg.Fps -and $null -ne $c.Fps -and [int]$script:Cfg.Fps -eq [int]$c.Fps)) {
            $marks += '<== current'
        }
        Write-Host ("  [{0}] {1} {2}" -f ($i + 1), $c.Label, ($marks -join ' '))
    }
    Write-Host ''
    Write-Host 'Type a number, then press Enter. Blank Enter keeps the current selection.' -ForegroundColor DarkGray

    $answer = (Read-Host 'Frame rate').Trim()
    if ($answer -eq '') { return }

    $n = 0
    if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $choices.Count) {
        $newFps = $choices[$n - 1].Fps
        if (($newFps -eq $null -and $null -eq $script:Cfg.Fps) -or
            ($null -ne $newFps -and $null -ne $script:Cfg.Fps -and [int]$newFps -eq [int]$script:Cfg.Fps)) { return }

        $old = $script:Cfg.Fps
        Invoke-CameraConfigChange -What "Frame rate -> $newFps" -ApplyNewValue {
            $script:Cfg.Fps = $newFps
        } -RestoreOldValue {
            $script:Cfg.Fps = $old
        }
        return
    }

    Write-Host 'Invalid selection.' -ForegroundColor Yellow
}

function Show-BitrateScreen {
    param([Parameter(Mandatory)]$Enc)

    while ($true) {
        Write-Host ''
        Write-Host 'Video Bitrate' -ForegroundColor Yellow
        Write-Host ''

        $defaultToken = ''
        if ([long]$script:Cfg.BitrateBps -eq $script:DefaultBitrateBps) { $defaultToken = ' [Default]' }

        Write-Host "  Current:  $(Format-Bitrate ([long]$script:Cfg.BitrateBps))$defaultToken"
        Write-Host "  Default:  $(Format-Bitrate $script:DefaultBitrateBps)"

        if (-not $Enc.Available) {
            Write-Host ''
            Write-Host '  Encoder bitrate capabilities could not be queried.' -ForegroundColor Yellow
            Write-Host '  Custom bitrate selection is unavailable; the proven default is used.' -ForegroundColor Yellow
            Write-Host ''
            Wait-ForEnter 'Press Enter to return'
            return
        }

        $effMin = [Math]::Max([long]$Enc.MinBps, [long]0)
        $effMax = [Math]::Min([long]$Enc.MaxBps, $script:Const.ScrcpyParserMaxBps)

        Write-Host "  Encoder:  $($Enc.EncoderName) ($($Enc.MimeType))"
        Write-Host "  Range:    $(Format-Bitrate $effMin) - $(Format-Bitrate $effMax)"
        Write-Host "  (scrcpy parser ceiling: $(Format-Bitrate $script:Const.ScrcpyParserMaxBps); UI steps are navigation-only)"

        if ([long]$script:DefaultBitrateBps -gt [long]$Enc.MaxBps) {
            Write-Host ''
            Write-Host '  Warning: this encoder reports a maximum below the already proven' -ForegroundColor Yellow
            Write-Host "  default ($(Format-Bitrate $script:DefaultBitrateBps) > $(Format-Bitrate ([long]$Enc.MaxBps)))." -ForegroundColor Yellow
            Write-Host '  The known-working default is preserved; vendor metadata may be off.' -ForegroundColor Yellow
        }

        Write-Host ''
        Write-Host '  [-] decrease   [+] increase (UI step only)   [V] enter exact value   [D] restore default   [Enter] back'
        Write-Host '  Type a key, then press Enter. Blank Enter goes back.' -ForegroundColor DarkGray

        $answer = (Read-Host 'Bitrate').Trim()
        if ($answer -eq '') { return }

        switch -Regex ($answer) {
            '^\+$' {
                $newVal = [long]$script:Cfg.BitrateBps + (Get-BitrateUiStep $effMin $effMax)
                if ($newVal -gt $effMax) { $newVal = $effMax }
                $old = $script:Cfg.BitrateBps
                Invoke-CameraConfigChange -What 'Bitrate' -ApplyNewValue { $script:Cfg.BitrateBps = $newVal } -RestoreOldValue { $script:Cfg.BitrateBps = $old }
            }
            '^-$' {
                $newVal = [long]$script:Cfg.BitrateBps - (Get-BitrateUiStep $effMin $effMax)
                if ($newVal -lt $effMin) { $newVal = $effMin }
                $old = $script:Cfg.BitrateBps
                Invoke-CameraConfigChange -What 'Bitrate' -ApplyNewValue { $script:Cfg.BitrateBps = $newVal } -RestoreOldValue { $script:Cfg.BitrateBps = $old }
            }
            '^(?i)V$' {
                $raw = (Read-Host 'Enter exact value (Mbps, e.g. 20 or 8.25)').Trim()
                $num = 0.0
                if ([double]::TryParse($raw, [ref]$num)) {
                    $newBps = [long]([Math]::Round($num * 1000000))
                    if ($newBps -lt $effMin -or $newBps -gt $effMax) {
                        Write-Host ''
                        Write-Host "ERROR: $(Format-Bitrate $newBps) is outside the encoder's reported range ($(Format-Bitrate $effMin) - $(Format-Bitrate $effMax))." -ForegroundColor Red
                        Write-Host 'scrcpy was not launched with the invalid value.' -ForegroundColor DarkGray
                    }
                    else {
                        $old = $script:Cfg.BitrateBps
                        Invoke-CameraConfigChange -What "Bitrate -> $newBps bps" -ApplyNewValue { $script:Cfg.BitrateBps = $newBps } -RestoreOldValue { $script:Cfg.BitrateBps = $old }
                        return
                    }
                }
                else {
                    Write-Host 'Invalid value.' -ForegroundColor Yellow
                }
            }
            '^(?i)D$' {
                $old = $script:Cfg.BitrateBps
                Invoke-CameraConfigChange -What 'Bitrate -> default' -ApplyNewValue { $script:Cfg.BitrateBps = $script:DefaultBitrateBps } -RestoreOldValue { $script:Cfg.BitrateBps = $old }
            }
            default {
                Write-Host 'Invalid choice.' -ForegroundColor Yellow
            }
        }
    }
}

function Show-LiveSettingsSteps {
    # Stepped live-camera configuration, negotiated against the phone's real
    # capabilities. Every pick allows Enter = keep the current value. Used by
    # the guided start and by [C] mid-session. Any change while a camera
    # session is live restarts it (OBS re-attaches within a second or so -
    # that brief blink on the preview is expected).
    Write-TuiSection 'Live camera settings'

    # resolve the device (reusing the connected session when there is one)
    $scrcpy = Resolve-Scrcpy
    $adb = Resolve-Adb -ScrcpyExe $scrcpy
    $device = if ($script:State.Serial -and (Is-SessionRunning)) {
        [pscustomobject]@{ Serial = $script:State.Serial; Model = ''; Status = 'device' }
    }
    else {
        Choose-Device -AdbExe $adb
    }
    $caps = Get-DeviceCapabilities -ScrcpyExe $scrcpy -Serial $device.Serial

    $camLabel = if ($null -ne $script:Cfg.CameraId) { "camera $($script:Cfg.CameraId)" } else { 'back (default)' }
    Write-Host "  Current: $camLabel, $($script:Cfg.CameraSize), $(if ($script:Cfg.Fps) { [string]$script:Cfg.Fps + ' FPS' } else { 'Android default FPS' }), $(Format-Bitrate ([long]$script:Cfg.BitrateBps))" -ForegroundColor Cyan
    Write-Host "  (the lists below come straight from the phone; nothing is invented)" -ForegroundColor DarkGray

    if (-not (Read-YesNo -Prompt 'Keep these camera settings?' -Default $true)) {
        Show-CameraPicker -Caps $caps | Out-Null
        Show-ResolutionPicker -Caps $caps
        Show-FpsPicker -Caps $caps
        Show-BitrateScreen
    }

    # final live summary after any changes
    Write-Host ''
    Write-Host "  Camera now: $(if ($null -ne $script:Cfg.CameraId) { 'camera ' + $script:Cfg.CameraId } else { 'back (default)' }), $($script:Cfg.CameraSize), $(if ($script:Cfg.Fps) { [string]$script:Cfg.Fps + ' FPS' } else { 'Android default FPS' }), $(Format-Bitrate ([long]$script:Cfg.BitrateBps))" -ForegroundColor Green
}

function Show-RecordingSettingsSteps {
    # Stepped recording configuration shown in the guided start and under [K].
    # The advanced full page is still available at the end of the flow.
    Write-TuiSection 'Recording settings'

    if ($script:Cfg.RecordTarget -eq 'Off') {
        Write-Host '  Nothing is set to record yet - choose what to capture:' -ForegroundColor Yellow
        $script:Cfg.RecordTarget = Read-RecordTargetChoice
        Save-Settings
    }

    Write-Host "  Target:    $($script:Cfg.RecordTarget)"
    Write-Host "  Container: $($script:Cfg.RecordContainer)   (mkv = crash-safe, mp4 = compatible)"
    Write-Host "  Video:     $($script:Cfg.RecordVideoPreset)"
    Write-Host "  Audio:     $($script:Cfg.RecordAudioMode)$(if ($script:Cfg.RecordAudioMode -in @('Aac','Opus')) { ' ' + [string]$script:Cfg.RecordAudioBitrateKbps + ' kbps' } else { '' })"
    Write-Host "  Folder:    $(Get-RecordOutputDir)"

    Read-DisconnectPolicyChoice

    if (-not (Read-YesNo -Prompt 'Keep these recording settings? (N opens the full settings page)' -Default $true)) {
        Show-RecordingSettings
    }
    if ($script:Cfg.RecordTarget -eq 'Off') {
        Write-Host '  Recording still needs a target - pick one now:' -ForegroundColor Yellow
        $script:Cfg.RecordTarget = Read-RecordTargetChoice
        Save-Settings
    }
}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

function Show-Diagnostics {
    Write-TuiHeader 'Diagnostics'

    try {
        $scrcpy = Resolve-Scrcpy
        $adb = Resolve-Adb -ScrcpyExe $scrcpy

        Write-Host "scrcpy:      $scrcpy"
        Write-Host "version:     $(Get-ScrcpyVersion -ScrcpyExe $scrcpy)"
        $compat = Test-ScrcpyCompatibility -ScrcpyExe $scrcpy
        Write-Host "compat:      $(if ($compat.Message) { $compat.Message } else { "validated range $($script:ScrcpyMinVersion)-$($script:ScrcpyTestedVersion)" })"
        Write-Host "adb:         $adb"
        Write-Host ''
        Write-Host 'ADB devices:'

        $devices = @(Get-AdbDevices -AdbExe $adb)

        if ($devices.Count -eq 0) {
            Write-Host '  none'
        }
        else {
            foreach ($d in $devices) {
                Write-Host "  $($d.Status)  $($d.Serial)  $($d.Model)"
            }
        }
    }
    catch {
        Write-Host "Preflight error: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host ''
    Write-Host 'Active WASAPI render endpoints:'

    try {
        $endpoints = @(Get-AudioRenderEndpoints)

        if ($endpoints.Count -eq 0) {
            Write-Host '  none'
        }
        else {
            foreach ($ep in $endpoints) {
                $mark = if ($ep.Id -eq $script:Cfg.AudioTargetId) { '  <-- selected' } else { '' }
                Write-Host "  $($ep.Name)$mark"
                Write-Host "      $($ep.Id)" -ForegroundColor DarkGray
            }
        }
    }
    catch {
        Write-Host "  endpoint enumeration failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    $screen = Get-PrimarySize

    Write-Host ''
    Write-Host "Operation:   $(Get-OperationLabel)"
    Write-Host "LIVE:        $(if (Is-SessionRunning) { Get-LiveSourceLabel } else { 'off' })"
    Write-Host "RECORDING:   $(if (Test-RecordingActive) { (Get-RecordingSourceLabel) + '  ' + (Recording-StatusLine) } else { 'off (target: ' + (Get-RecordingSourceLabel) + ')' })"
    Write-Host ''
    Write-Host "Primary:     $($screen.Width)x$($screen.Height)"
        Write-Host "Requested:   camera $($script:Cfg.CameraSize), $(Format-Bitrate ([long]$script:Cfg.BitrateBps)), fps $(if ($script:Cfg.Fps) { [string]$script:Cfg.Fps } else { 'Android default' })"
    Write-Host "Mode:        $(Get-ModeStatusLabel)"
    Write-Host "Rotation:    $(Get-RotationLabel ([int]$script:Cfg.Rotation)) (scrcpy --orientation=$(ConvertTo-ScrcpyOrientation ([int]$script:Cfg.Rotation)))"
    Write-Host "State:       $($script:State.SessionState)"

    if (Test-ModeAudio) {
        Write-Host "Phone mic:   $(Get-AudioDetailLabel) (required=$($script:Cfg.RequireAudio))"
    }

    Write-Host "Parking:     $($script:Cfg.ParkingMode)"
    Write-Host "Session PID: $($script:State.Pid)"

    if (Is-SessionRunning -and $script:State.Hwnd -ne [IntPtr]::Zero) {
        $rect = Get-WindowRectInfo -Hwnd $script:State.Hwnd
        if ($rect) {
            Write-Host "Window:      $($rect.Width)x$($rect.Height) at $($rect.X),$($rect.Y)"
        }
    }

    Write-Host "Settings:    $script:ConfigFile"
    Write-Host "Log:         $script:LogFile"
    Write-Host "Media ports: server $($script:VideoServerPort)/$($script:AudioServerPort), relay $($script:VideoRelayPort)/$($script:AudioRelayPort), placeholder $($script:VideoPlaceholderPort)/$($script:AudioPlaceholderPort)"
    Write-Host ''
    Wait-ForEnter 'Press Enter to return'
}

function Test-ScrcpyInConsole {
    $scrcpy = Resolve-Scrcpy
    $adb = Resolve-Adb -ScrcpyExe $scrcpy
    $device = Choose-Device -AdbExe $adb

    Write-Host ''
    Write-Host 'Launching scrcpy attached to this terminal for VIDEO diagnostics.' -ForegroundColor Yellow
    Write-Host 'Audio is disabled in this diagnostic mode so the phone mic cannot spill to speakers.'
    Write-Host 'Close the scrcpy window to return to the TUI.'
    Write-Host ''

    $args = Get-ScrcpyArgumentList `
        -Serial $device.Serial `
        -Mode CameraOnly `
        -TitleOverride "$($script:Cfg.WindowTitle) TEST"

    & $scrcpy @args

    Write-Host ''
    Wait-ForEnter 'Press Enter to return'
}

# ---------------------------------------------------------------------------
# TUI
# ---------------------------------------------------------------------------

# Shared look: one banner, aligned key hints, a framed status card.
# ASCII-only borders so the layout survives any console code page.

function Write-TuiHeader {
    param([string]$Page = '')
    try { Clear-Host } catch { }  # piped/headless output has no console to clear
    $line = '=' * 62
    Write-Host $line -ForegroundColor DarkCyan
    $title = "  scrcpy-camera-helper v$script:Version"
    if ($Page) { $title += "  -  $Page" }
    Write-Host $title -ForegroundColor Cyan
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-TuiSection {
    param([string]$Label)
    Write-Host ''
    Write-Host " $Label" -ForegroundColor Yellow
    Write-Host (' ' + ('-' * ([Math]::Min(58, $Label.Length + 2)))) -ForegroundColor DarkGray
}

function Write-TuiKey {
    # one aligned menu row:  [KEY]  label  ....  hint
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Text,
        [string]$Hint = ''
    )
    $left = "  [{0}]  {1}" -f $Key, $Text
    if ($Hint) {
        Write-Host $left -NoNewline
        Write-Host (" " * [Math]::Max(1, 42 - $left.Length) + $Hint) -ForegroundColor DarkGray
    }
    else {
        Write-Host $left
    }
}

function Show-TuiStatus {
    $obs = if (Test-ModeVideo -and $script:Cfg.Mode -ne 'RecordOnly') { $script:Cfg.WindowTitle } else { '(no live window)' }

    # Top rows are the contract: WHAT is running and WHICH source each side of
    # it uses. Live and Recording are independent operations, so they get
    # independent source lines even when both run at once.
    $op        = Get-OperationLabel
    $liveNow   = Is-SessionRunning
    $recNow    = Test-RecordingActive
    $liveRow   = if ($liveNow) { Get-LiveSourceLabel } else { 'off  (configured: ' + (Get-LiveSourceLabel) + ')' }
    $recRow    = if ($recNow)  { (Get-RecordingSourceLabel) + '  ' + (Recording-StatusLine) } else { 'off  (target: ' + (Get-RecordingSourceLabel) + ')' }

    $rows = @(
        ('Status:    ' + (Status-Line)),
        ('Rotation:  ' + (Get-RotationLabel ([int]$script:Cfg.Rotation))),
        ('Audio out: ' + $(if ($script:Cfg.AudioTargetName) { [string]$script:Cfg.AudioTargetName } else { '(not selected)' })),
        ('Camera:    ' + $script:Cfg.CameraSize + ' @ ' + $(if ($script:Cfg.Fps) { [string]$script:Cfg.Fps + ' FPS' } else { 'default fps' }) + ', ' + (Format-Bitrate ([long]$script:Cfg.BitrateBps)) + ', ' + $(if ($null -ne $script:Cfg.CameraId) { "camera $($script:Cfg.CameraId)" } else { 'back' })),
        ('Parking:   ' + $script:Cfg.ParkingMode),
        ('OBS sees:  ' + $obs)
    )

    $width = 60
    $edge = ' +' + ('-' * $width) + '+'
    Write-Host $edge -ForegroundColor DarkGray

    $opClipped = "OPERATION: $op"
    if ($opClipped.Length -gt $width - 1) { $opClipped = $opClipped.Substring(0, $width - 4) + '...' }
    Write-Host (' | ' + $opClipped.PadRight($width - 1) + '|') -ForegroundColor $(if ($op -eq 'Stopped') { 'DarkGray' } else { 'Green' })

    foreach ($r in @("LIVE:      $liveRow", "RECORDING: $recRow")) {
        $clipped = if ($r.Length -gt $width - 1) { $r.Substring(0, $width - 4) + '...' } else { $r }
        Write-Host (' | ' + $clipped.PadRight($width - 1) + '|') -ForegroundColor Cyan
    }

    Write-Host (' |' + ('-' * $width) + '|') -ForegroundColor DarkGray
    foreach ($r in $rows) {
        $clipped = if ($r.Length -gt $width - 1) { $r.Substring(0, $width - 4) + '...' } else { $r }
        Write-Host (' | ' + $clipped.PadRight($width - 1) + '|') -ForegroundColor Gray
    }
    Write-Host $edge -ForegroundColor DarkGray
}

function Status-Line {
    $s = [string]$script:State.SessionState
    if ($s -eq 'Running' -and (Is-SessionRunning)) {
        return "RUNNING (PID $($script:State.Pid), $s)"
    }
    if ($s -eq 'Running' -and (Test-RecordingActive)) {
        # Recording Only: no live PID is expected by design - the file is the op.
        return 'RECORDING WITHOUT LIVE (servers + FFmpeg)'
    }
    if ($s -eq 'Running' -and -not (Is-SessionRunning)) {
        # scrcpy died unexpectedly while we believed it was running.
        return 'FAILED (scrcpy exited unexpectedly - use [2] Stop to reset)'
    }
    return $s.ToUpper()
}

function Recording-StatusLine {
    $r = $script:State.Recording
    if (-not $r) {
        return "Off   (target: $($script:Cfg.RecordTarget))"
    }
    $dur = (Get-Date) - $r.StartedAt
    $durText = '{0:00}:{1:00}' -f [int]$dur.TotalMinutes, $dur.Seconds
    $sizeOf = if ($r.OutFile -and (Test-Path -LiteralPath $r.OutFile -PathType Leaf)) {
        $sz = (Get-Item -LiteralPath $r.OutFile).Length
        "{0:N1} MB" -f ($sz / 1MB)
    } else { '-' }
    return "$($r.State.ToUpper()) ($durText) -> $([IO.Path]::GetFileName($r.OutFile)) [$sizeOf] (ffmpeg pid $($r.Pid))"
}

function Show-RecordingSettings {
    while ($true) {
        Write-TuiHeader 'Recording settings (FFmpeg)'
        Write-Host '  Everything here is written by FFmpeg; there is no built-in recorder.' -ForegroundColor DarkGray

        Write-Host "  [1] Target        : $($script:Cfg.RecordTarget)   (Off / Video / Audio / VideoAudio)"
        Write-Host "  [2] Output        : $(if ($script:Cfg.RecordDirMode -eq 'Custom' -and $script:Cfg.RecordDir) { $script:Cfg.RecordDir } else { 'Same as script folder' })"
        Write-Host "  [3] Container     : $($script:Cfg.RecordContainer)   (mkv default; crash-safe; mp4 = compatibility)"
        Write-Host "  [4] Video preset  : $($script:Cfg.RecordVideoPreset)"
        Write-Host "  [5] Audio codec   : $($script:Cfg.RecordAudioMode)"
        Write-Host "  [6] Audio bitrate : $($script:Cfg.RecordAudioBitrateKbps) kbps (lossy codecs only)"
        $vbLine = "  [7] Video bitrate : $(if ([long]$script:Cfg.RecordVideoBitrateBps -gt 0) { Format-Bitrate ([long]$script:Cfg.RecordVideoBitrateBps) } else { '(match live camera)' })"
        Write-Host "$vbLine   (only when the preset transcodes)"
        Write-Host "  [8] Custom args   : $(if ($script:Cfg.RecordCustomArgs) { [string]$script:Cfg.RecordCustomArgs } else { '(none)' })"
        $ffDisp = if ($script:Cfg.FFmpegPath) { $script:Cfg.FFmpegPath } else { '(auto-detect)' }
        Write-Host "  [9] FFmpeg        : $ffDisp"
        Write-Host "  [0] Disconnect    : $($script:Cfg.DisconnectPolicy)   (Placeholder = bridge the gap / Split = new file)"
        Write-Host '  [D] Restore recording defaults'
        Write-Host ''
        Write-Host 'Type a number or letter, then press Enter to change that setting.' -ForegroundColor DarkGray
        Write-Host 'When you are done, press Enter on a blank line to return to the main menu.' -ForegroundColor DarkGray

        if (Test-RecordingActive) {
            Write-Host ''
            Write-Host ' NOTE: a recording is ACTIVE - changes apply to the NEXT recording.' -ForegroundColor Yellow
        }

        $answer = (Read-Host 'Choice').Trim()
        if ($answer -eq '') { return }

        try {
            switch -Regex ($answer) {
                '^1$' {
                    Write-Host 'Options: [O] Off  [V] Video only  [A] Audio only  [B] Both (video+audio)' -ForegroundColor DarkGray
                    $a = (Read-Host 'Record target').Trim().ToUpperInvariant()
                    $new = switch ($a) { 'V' { 'Video' } 'A' { 'Audio' } 'B' { 'VideoAudio' } 'O' { 'Off' } default { $script:Cfg.RecordTarget } }
                    if ($new -ne $script:Cfg.RecordTarget) { $script:Cfg.RecordTarget = $new; Save-Settings }
                }
                '^2$' {
                    Write-Host 'Blank = same folder as this script. Or enter a full directory path:' -ForegroundColor DarkGray
                    $a = (Read-Host 'Output directory').Trim().Trim('"')
                    if ($a -eq '') { $script:Cfg.RecordDirMode = 'Script'; $script:Cfg.RecordDir = '' }
                    else { $script:Cfg.RecordDirMode = 'Custom'; $script:Cfg.RecordDir = $a }
                    Save-Settings
                }
                '^3$' {
                    Write-Host 'Containers: [M]kv  mp[4]' -ForegroundColor DarkGray
                    $a = (Read-Host 'Container').Trim().ToLowerInvariant()
                    if ($a -in @('mkv','m')) { $script:Cfg.RecordContainer = 'mkv' }
                    elseif ($a -in @('mp4','4')) { $script:Cfg.RecordContainer = 'mp4' }
                    Save-Settings
                }
                '^4$' {
                    if (Test-RecordingLocked 'video preset') { break }
                    Write-Host "Video preset:"
                    Write-Host '  [C] Same-as-source (stream copy; lowest CPU)'
                    Write-Host '  [B] Balanced (re-encode x264 crf23)'
                    Write-Host '  [H] High quality (x264 crf18)'
                    Write-Host '  [S] Storage efficient (x265 crf30)'
                    Write-Host '  [X] Custom FFmpeg args'
                    $a = (Read-Host 'Preset').Trim().ToUpperInvariant()
                    $map = @{ C = 'Copy'; B = 'Balanced'; H = 'HighQuality'; S = 'StorageEfficient'; X = 'Custom' }
                    if ($map.ContainsKey($a)) {
                        if ($a -eq 'X') {
                            $current = [string]$script:Cfg.RecordCustomArgs
                            Write-Host "Current custom args: $(if ($current) { $current } else { '(none)' })"
                            $raw = (Read-Host 'New output-side FFmpeg args (or blank to clear)').Trim('"')
                            if ($raw) {
                                $chk = Test-CustomArgs $raw
                                if (-not $chk.Ok) { Write-Host "Rejected: $($chk.Reason)" -ForegroundColor Red; break }
                                $script:Cfg.RecordCustomArgs = $raw
                            }
                        }
                        $script:Cfg.RecordVideoPreset = $map[$a]
                        Save-Settings
                    }
                }
                '^5$' {
                    if (Test-RecordingLocked 'audio codec') { break }
                    Write-Host 'Audio codec: [C]opy  [A]AC  [O]pus  [F]LAC  [P]CM'
                    $a = (Read-Host 'Codec').Trim().ToUpperInvariant()
                    $map = @{ C = 'Copy'; A = 'Aac'; O = 'Opus'; F = 'Flac'; P = 'Pcm' }
                    if ($map.ContainsKey($a)) { $script:Cfg.RecordAudioMode = $map[$a]; Save-Settings }
                }
                '^6$' {
                    if (Test-RecordingLocked 'audio bitrate') { break }
                    $a = (Read-Host 'Audio bitrate in kbps (e.g. 192)').Trim()
                    $n = 0
                    if ([int]::TryParse($a, [ref]$n) -and $n -ge 32 -and $n -le 1024) { $script:Cfg.RecordAudioBitrateKbps = $n; Save-Settings }
                    else { Write-Host '32..1024 kbps only.' -ForegroundColor Yellow }
                }
                '^7$' {
                    if (Test-RecordingLocked 'video bitrate') { break }
                    $a = (Read-Host 'Video bitrate in Mbps (blank = match live camera)').Trim()
                    if ($a -eq '') { $script:Cfg.RecordVideoBitrateBps = 0; Save-Settings; break }
                    $n = 0.0
                    if ([double]::TryParse($a, [ref]$n)) {
                        $bps = [long]([Math]::Round($n * 1000000))
                        # bounded by the encoder the device will actually use:
                        $enc = $null
                        try {
                            if ($script:State.Serial -and $script:CapCache) { $encoder = $script:State.EncoderName }
                            else {
                                $sc = $script:State.ScrcpyExe; if (-not $sc) { $sc = Resolve-Scrcpy }
                                $adb = $script:State.AdbExe; if (-not $adb) { $adb = Resolve-Adb -ScrcpyExe $sc }
                                $ser = $script:State.Serial; if (-not $ser) {
                                    $encDev = Choose-Device -AdbExe $adb
                                    $ser = $encDev.Serial; $script:State.Serial = $ser
                                }
                                $caps = Get-DeviceCapabilities -ScrcpyExe $sc -Serial $ser
                                $enc = Resolve-EncoderCapabilities -AdbExe $adb -Serial $ser -Caps $caps
                            }
                        }
                        catch {
                            Log "encoder range lookup failed during bitrate edit: $($_.Exception.Message)"
                            $enc = $null
                        }
                        if ($enc -and $enc.Available) {
                            $min = [long]$enc.MinBps; $max = [Math]::Min([long]$enc.MaxBps, [long]$script:Const.ScrcpyParserMaxBps)
                            if ($bps -lt $min -or $bps -gt $max) {
                                Write-Host "ERROR: $(Format-Bitrate $bps) is outside the encoder range ($(Format-Bitrate $min) - $(Format-Bitrate $max))." -ForegroundColor Red
                                Write-Host 'Nothing was changed.' -ForegroundColor DarkGray
                                break
                            }
                        }
                        else {
                            Write-Host 'Encoder bitrate range is unavailable right now - custom values disabled.' -ForegroundColor Yellow
                            break
                        }
                        $script:Cfg.RecordVideoBitrateBps = $bps; Save-Settings
                    }
                    else { Write-Host 'Invalid number.' -ForegroundColor Yellow }
                }
                '^8$' {
                    if (Test-RecordingLocked 'custom args') { break }
                    $current = [string]$script:Cfg.RecordCustomArgs
                    Write-Host "Current: $(if ($current) { $current } else { '(none)' })"
                    Write-Host '  (appended after presets on the output side; input/output paths stay app-controlled)'
                    $raw = (Read-Host 'Custom args (blank clears)').Trim()
                    if ($raw -eq '') { $script:Cfg.RecordCustomArgs = '' }
                    else {
                        $chk = Test-CustomArgs $raw
                        if (-not $chk.Ok) { Write-Host "Rejected: $($chk.Reason)" -ForegroundColor Red; break }
                        $script:Cfg.RecordCustomArgs = $raw
                    }
                    Save-Settings
                }
                '^0$' {
                    if (Test-RecordingLocked 'disconnect behavior') { break }
                    Read-DisconnectPolicyChoice
                }
                '^9$' {
                    if (Test-RecordingLocked 'FFmpeg path') { break }
                    $a = (Read-Host 'Path to ffmpeg.exe (blank = re-detect)').Trim().Trim('"')
                    if ($a -eq '') { $script:Cfg.FFmpegPath = '' } else {
                        $ok = Test-FFmpegBinary $a
                        if ($ok) { $script:Cfg.FFmpegPath = $ok } else { Write-Host 'Not a valid ffmpeg.exe.' -ForegroundColor Red; break }
                    }
                    Save-Settings
                }
                '^(?i)D$' {
                    if (Test-RecordingLocked 'all') { break }
                    $script:Cfg.RecordTarget = 'Off'; $script:Cfg.RecordDirMode = 'Script'; $script:Cfg.RecordDir = ''
                    $script:Cfg.RecordContainer = 'mkv'; $script:Cfg.RecordVideoPreset = 'Copy'
                    $script:Cfg.RecordAudioMode = 'Copy'; $script:Cfg.RecordAudioBitrateKbps = 192
                    $script:Cfg.RecordVideoBitrateBps = 0; $script:Cfg.RecordCustomArgs = ''
                    $script:Cfg.RecordFps = 0; $script:Cfg.RecordResolution = ''
                    Save-Settings
                }
            }
        }
        catch {
            Log "recording settings error: $($_.Exception.Message)"
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
            Wait-ForEnter 'Press Enter'
        }
    }
}

function Get-MenuSignature {
    # Everything visible on the main screen folded into one cheap string; the
    # menu re-renders the moment this changes (state flips, a device
    # (dis)connect banner, the recording timer rolling over a second) instead
    # of waiting for the next keypress.
    $r = $script:State.Recording
    $recSig = 'off'
    if ($r) {
        $d = (Get-Date) - $r.StartedAt
        $recSig = '{0}:{1:00}:{2:00}:{3}' -f $r.State, [int]$d.TotalMinutes, $d.Seconds, [string]$r.OutFile
    }
    return (@(
        [string]$script:State.SessionState
        [string][int]$script:State.Pid
        [string](Is-SessionRunning)
        [string][bool]$script:State.DeviceDisconnected
        [string][bool]$script:State.AwaitingReconnect
        $recSig
    ) -join '|')
}

function Show-Help {
    Write-TuiHeader 'Help'

    Write-TuiSection 'Session (live and recording stop independently)'
    Write-TuiKey '1' 'Start' 'guided step-by-step setup'
    Write-TuiKey 'G' 'Stop Recording' 'live, if any, keeps running -> Live Only'
    Write-TuiKey 'T' 'Stop Live' 'recording, if any, keeps running -> Recording Only'
    Write-TuiKey '2' 'Stop Live / Stop Both' 'exactly what it ends is spelled out in the menu'
    Write-TuiKey '3' 'Restart live' 'only while nothing is recording'
    Write-TuiKey 'Q' 'Quit' 'only once live and recording are both stopped'

    Write-TuiSection 'Live modes (instant switch)'
    Write-TuiKey 'V' 'Video only' 'camera picture, no audio'
    Write-TuiKey 'B' 'Camera + mic' 'picture and sound'
    Write-TuiKey 'S' 'Sound only' 'mic, no window'
    Write-TuiKey 'F' 'Record only' 'file, no live window'

    Write-TuiSection 'Recording (FFmpeg)'
    Write-TuiKey 'G' 'Start / stop recording' 'stopping always finalizes'
    Write-TuiKey 'K' 'Recording settings' 'target, format, codecs'

    Write-TuiSection 'Camera + audio'
    Write-TuiKey '0/9/N/8/7' 'Rotation' '0 / +90 / -90 / +180 / -180'
    Write-TuiKey 'C' 'Camera settings' 'camera, size, fps, bitrate'
    Write-TuiKey 'E' 'Audio output device' 'searchable picker'
    Write-TuiKey 'R' 'Re-apply audio route'

    Write-TuiSection 'Advanced'
    Write-TuiKey '4' 'Window parking' 'Underlay / EdgeAnchor'
    Write-TuiKey '5' 'Diagnostics' 'versions, device, endpoints'
    Write-TuiKey '6' 'Run scrcpy visibly' 'troubleshooting'

    Write-Host ''
    Write-Host '  All of this is documented in detail in README.md.' -ForegroundColor DarkGray
    Write-Host ''
    Wait-ForEnter 'Press Enter to return'
}

function Menu {
    :menuLoop while ($true) {
        Write-TuiHeader

        Show-TuiStatus

        if ($script:State.SessionState -eq 'Failed') {
            Write-Host ''
            Write-Host '  !! Last transition FAILED - [2] Stop cleans up, then retry.' -ForegroundColor Red
        }

        if ($script:State.SessionState -eq 'Stopped') {
            Write-Host ''
            Write-Host '  Not started yet - [1] walks you through everything, step by step.' -ForegroundColor DarkGray
        }

        $liveM = Is-SessionRunning
        $recM  = Test-RecordingActive

        Write-TuiSection 'Session'
        if ($liveM -and $recM) {
            Write-TuiKey 'G' 'Stop Recording' 'live stays on -> Live Only'
            Write-TuiKey 'T' 'Stop Live' 'recording keeps going -> Recording Only'
            Write-TuiKey '2' 'Stop Both' 'everything stops -> Stopped'
            Write-TuiKey 'Q' 'Quit' 'stop Live and Recording first - quitting is not a stop action'
        }
        elseif ($liveM) {
            Write-TuiKey 'G' 'Start Recording' 'record alongside the live session'
            Write-TuiKey '2' 'Stop Live'
            Write-TuiKey '3' 'Restart live' 'reloads the preview with current settings'
            Write-TuiKey 'Q' 'Quit' 'stop Live first - quitting is not a stop action'
        }
        elseif ($recM) {
            Write-TuiKey 'G' 'Stop Recording' 'finalizes the file -> Stopped'
            Write-TuiKey 'Q' 'Quit' 'stop Recording first - quitting is not a stop action'
        }
        else {
            Write-TuiKey '1' 'Start (guided setup)' 'answers become your defaults'
            if ($script:State.SessionState -eq 'Failed') {
                Write-TuiKey '2' 'Clean up failed session'
            }
            Write-TuiKey 'Q' 'Quit'
        }

        Write-TuiSection 'Live modes'
        Write-TuiKey 'V' 'Video only' 'camera, no audio'
        Write-TuiKey 'B' 'Camera + mic' 'picture and sound'
        Write-TuiKey 'S' 'Sound only' 'mic, no window'
        Write-TuiKey 'F' 'Record only' 'straight to file'

        Write-TuiSection 'Recording'
        Write-TuiKey 'G' 'Start / stop recording' 'independent of live - see Session section'
        Write-TuiKey 'K' 'Recording settings' 'target, format, codecs'

        Write-TuiSection 'Camera + audio'
        Write-TuiKey 'C' 'Camera settings' 'read from your phone'
        Write-TuiKey '0' 'Rotation 0 deg'
        Write-TuiKey '9' 'Rotation +90'
        Write-TuiKey 'N' 'Rotation -90'
        Write-TuiKey '8' 'Rotation +180'
        Write-TuiKey '7' 'Rotation -180'
        Write-TuiKey 'E' 'Audio output device' 'searchable picker'
        Write-TuiKey 'R' 'Re-apply audio route'

        Write-TuiSection 'Advanced'
        Write-TuiKey '4' 'Window parking' 'Underlay / EdgeAnchor'
        Write-TuiKey '5' 'Diagnostics'
        Write-TuiKey '6' 'Run scrcpy visibly' 'troubleshooting'
        Write-TuiKey '?' 'Help'

        switch ([string]$script:Cfg.Mode) {
            'CameraOnly' {
                Write-Host ''
                Write-Host '  Camera only: no audio stream exists - OBS Window Capture has nothing to conflict with.' -ForegroundColor DarkGray
            }
            'CameraAudio' {
                Write-Host ''
                Write-Host '  Camera + mic: the mic plays into the output above; apps listen on its capture side.' -ForegroundColor DarkGray
                Write-Host '  Never monitor OBS back into that same device.' -ForegroundColor DarkGray
            }
            'AudioOnly' {
                Write-Host ''
                Write-Host '  Sound only: mic goes to the output above; no window exists for OBS right now.' -ForegroundColor DarkGray
            }
            'RecordOnly' {
                Write-Host ''
                Write-Host '  Record only: no live window; [G] starts/stops the file recording.' -ForegroundColor DarkGray
            }
        }

        Write-Host ''
        # Non-blocking key poll: device-watch events and the recording watchdog
        # stay alive while the menu idles, and any change to the visible state
        # re-renders the screen immediately.
        $choice = $null
        $sig = Get-MenuSignature
        while (-not $Host.UI.RawUI.KeyAvailable) {
            Update-DisconnectState
            Update-RecordingHealth
            Start-Sleep -Milliseconds 200
            if ((Get-MenuSignature) -ne $sig) { continue menuLoop }
        }
        $rk = $Host.UI.RawUI.ReadKey('IncludeKeyDown,NoEcho')
        $choice = ([string]$rk.Character).Trim().ToUpperInvariant()

        try {
            switch ($choice) {
                '1' {
                    if ((Is-SessionRunning) -or (Test-RecordingActive)) {
                        Write-Host "Already running: $(Get-OperationLabel). Stop what is running first (Session section)." -ForegroundColor Yellow
                        Wait-ForEnter
                    }
                    else {
                        Invoke-StartFlow
                        Wait-ForEnter
                    }
                }

                '2' {
                    Assert-TransitionAllowed
                    if ((Is-SessionRunning) -and (Test-RecordingActive)) {
                        # Stop Both: recording finalizes first (with its one-time
                        # cleanup prompts), then the live leg goes down.
                        Stop-RecordingWithCleanup
                        Stop-Camera
                        Set-TransitionState 'Stopped'
                        Write-Host ''
                        Write-Host 'Both stopped - status is now Stopped.' -ForegroundColor Green
                        Wait-ForEnter
                    }
                    elseif (Is-SessionRunning) {
                        # Stop Live (nothing is being recorded, so this is the
                        # only active operation).
                        Stop-Camera
                        Set-TransitionState 'Stopped'
                        Start-Sleep -Milliseconds 300
                    }
                    elseif (Test-RecordingActive) {
                        Write-Host 'Only a recording is running - use [G] Stop Recording to end it.' -ForegroundColor DarkGray
                        Wait-ForEnter
                    }
                    else {
                        Stop-Camera    # also the Failed-state cleanup path
                        Set-TransitionState 'Stopped'
                        Start-Sleep -Milliseconds 300
                    }
                }

                '3' {
                    if (Test-RecordingActive) {
                        Write-Host 'A recording is running - a live restart would drop recorded frames.' -ForegroundColor Yellow
                        Write-Host 'Stop the recording first ([G] Stop Recording or [2] Stop Both).' -ForegroundColor DarkGray
                        Wait-ForEnter
                    }
                    elseif (Is-SessionRunning) {
                        Invoke-SessionRestart -Reason 'manual restart'
                        Wait-ForEnter
                    }
                    else {
                        Write-Host 'Nothing is running yet - [1] walks you through setup.' -ForegroundColor DarkGray
                        Wait-ForEnter
                    }
                }

                'T' {
                    Assert-TransitionAllowed
                    Stop-LiveSession
                    Wait-ForEnter
                }

                'V' {
                    Set-SessionMode -NewMode 'CameraOnly'
                    Wait-ForEnter
                }

                'B' {
                    Set-SessionMode -NewMode 'CameraAudio'
                    Wait-ForEnter
                }

                'S' {
                    Set-SessionMode -NewMode 'AudioOnly'
                    Wait-ForEnter
                }

                'F' {
                    Set-SessionMode -NewMode 'RecordOnly'
                    Wait-ForEnter
                }

                'G' {
                    try {
                        if (Test-RecordingActive) {
                            # Stop Recording is independent: live, if any, keeps
                            # running (server producers + relays stay up; only the
                            # FFmpeg consumer finishes its file).
                            Stop-RecordingWithCleanup
                            Stop-RecordingInfraIfIdle
                            Write-Host ''
                            if (Is-SessionRunning) {
                                Write-Host 'Recording stopped. Live continues - status is now Live Only.' -ForegroundColor Green
                            }
                            else {
                                Write-Host 'Recording stopped. Status is now Stopped.' -ForegroundColor Green
                                Set-TransitionState 'Stopped'
                            }
                        }
                        else {
                            Start-Recording
                            if ((Test-RecordingActive) -and -not (Is-SessionRunning)) {
                                # recording without a live leg: keep the state line honest
                                Set-TransitionState 'Running'
                            }
                        }
                    } catch {
                        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
                    }
                    Wait-ForEnter
                }

                'K' {
                    $wasRecording = Test-RecordingActive
                    if ($wasRecording) {
                        Write-Host ''
                        Write-Host 'A recording is running - changing recording settings requires stopping it first.' -ForegroundColor Yellow
                        if (Is-SessionRunning) {
                            Write-Host 'Only the file recording stops; live keeps running (-> Live Only).' -ForegroundColor Yellow
                        }
                        Write-Host ''
                        if (-not (Read-YesNo -Prompt 'Stop the recording and edit the settings now?' -Default $false)) {
                            Wait-ForEnter
                            continue
                        }
                        Stop-RecordingWithCleanup
                        Stop-RecordingInfraIfIdle
                        if (Is-SessionRunning) {
                            Write-Host 'Recording stopped. Still live - status is now Live Only.' -ForegroundColor Green
                        }
                        else {
                            Write-Host 'Recording stopped. Status is now Stopped.' -ForegroundColor Green
                            Set-TransitionState 'Stopped'
                        }
                        Write-Host ''
                    }

                    Show-RecordingSettingsSteps

                    if ($wasRecording -and (Read-YesNo -Prompt 'Start recording again with these settings now?' -Default $true)) {
                        try {
                            Start-Recording
                            if ((Test-RecordingActive) -and -not (Is-SessionRunning)) {
                                # recording without a live leg: keep the state line honest
                                Set-TransitionState 'Running'
                            }
                        } catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red }
                    }
                    Wait-ForEnter
                }

                'C' {
                    if (Is-SessionRunning) {
                        Write-Host 'Note: the preview will blink briefly when a camera setting' -ForegroundColor DarkYellow
                        Write-Host 'changes (the session restarts); your OBS source stays attached.' -ForegroundColor DarkYellow
                        Write-Host ''
                    }
                    Show-LiveSettingsSteps
                    Wait-ForEnter
                }

                '0' {
                    Set-SessionRotation -Degrees 0
                    Wait-ForEnter
                }

                '9' {
                    Set-SessionRotation -Degrees 90
                    Wait-ForEnter
                }

                'N' {
                    Set-SessionRotation -Degrees -90
                    Wait-ForEnter
                }

                '8' {
                    Set-SessionRotation -Degrees 180
                    Wait-ForEnter
                }

                '7' {
                    Set-SessionRotation -Degrees -180
                    Wait-ForEnter
                }

                'E' {
                    $pick = Select-AudioTarget
                    if ($pick) {
                        Write-Host ''
                        Write-Host "Audio output: $($pick.Name)" -ForegroundColor Green
                    }
                    else {
                        Write-Host ''
                        Write-Host 'Selection cancelled.' -ForegroundColor DarkGray
                    }
                    Wait-ForEnter
                }

                'R' {
                    Invoke-ReapplyRoute
                    Wait-ForEnter
                }

                '4' {
                    Toggle-Parking
                    Start-Sleep -Milliseconds 300
                }

                '5' {
                    Show-Diagnostics
                }

                '6' {
                    if ((Is-SessionRunning) -or (Test-RecordingActive)) {
                        # A second visible scrcpy would fight the running
                        # producer for the single camera/mic capture.
                        Write-Host "Active right now: $(Get-OperationLabel)." -ForegroundColor Yellow
                        Write-Host 'A visible scrcpy window can only open while nothing is running -' -ForegroundColor Yellow
                        Write-Host 'stop the current operation first (Session section).' -ForegroundColor DarkGray
                        Wait-ForEnter
                    }
                    else {
                        Test-ScrcpyInConsole
                    }
                }

                { $_ -in @('?', 'H') } {
                    Show-Help
                }

                'Q' {
                    $liveQ = Is-SessionRunning
                    $recQ  = Test-RecordingActive
                    if ($liveQ -or $recQ) {
                        # Quit is never a stand-in for stopping: each operation
                        # ends through its own key; Q only fires when nothing runs.
                        Write-Host ''
                        Write-Host "Cannot quit yet - $(Get-OperationLabel) is active." -ForegroundColor Yellow
                        Write-Host 'Quit is not a stop action. Stop each running operation first:' -ForegroundColor DarkGray
                        if ($recQ) {
                            $howRec = if ($liveQ) { '[G] Stop Recording or [2] Stop Both' } else { '[G] Stop Recording' }
                            Write-Host "  RECORDING: $(Get-RecordingSourceLabel) - $howRec" -ForegroundColor Yellow
                        }
                        if ($liveQ) {
                            $howLive = if ($recQ) { '[T] Stop Live (recording keeps going) or [2] Stop Both' } else { '[2] Stop Live' }
                            Write-Host "  LIVE:      $(Get-LiveSourceLabel) - $howLive" -ForegroundColor Yellow
                        }
                        Write-Host 'When nothing is running, [Q] quits normally.' -ForegroundColor DarkGray
                        Wait-ForEnter
                    }
                    else {
                        return
                    }
                }
            }
        }
        catch {
            Log "ERROR: $($_.Exception.Message)"
            Write-Host ''
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host ''
            Wait-ForEnter
        }
    }
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

if (-not $script:IsDotSourced) {
    try {
        Load-Settings

        # First-run self-materialization: write a settings file with the
        # current (default) values right at launch, so the file always exists
        # after first launch and is honored when present.
        if (-not (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf)) {
            Save-Settings
            Log "Created settings file: $script:ConfigFile"
        }

        # Command-line overrides, if any: applied after loading and remembered
        # like a choice made in the menu.
        if ($PSBoundParameters.ContainsKey('Mode')) {
            $script:Cfg.Mode = [string]$Mode
            Save-Settings
            Log "Mode set from command line: $Mode"
        }
        if ($null -ne $Rotation) {
            $script:Cfg.Rotation = [int]$Rotation
            Save-Settings
            Log "Rotation set from command line: $Rotation"
        }

        # Select actually-free media ports once for this app lifetime.
        Resolve-MediaPorts

        # The log file (scrcpy-camera-helper.log) self-creates via the first Log write
        # above/below; the hidden-launcher VBS self-creates per launch; the
        # settings file was just handled. Nothing external is required.
        Log "scrcpy-camera-helper started (v$script:Version)"

        # --- Takeover: another running copy of this script, or leftover scrcpy
        # sessions (windowed OR windowless/orphaned) - shut them all down
        # safely, then take over. Latest instance always wins gracefully.
        $otherTuiPids = @()
        try {
            $procs = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue

            $otherTuiPids = @($procs | Where-Object {
                $_.ProcessId -ne $PID -and
                $_.CommandLine -and
                ($_.CommandLine -match '(?i)-File') -and
                ($_.CommandLine -match '(?i)scrcpy-camera-helper\.ps1')
            } | ForEach-Object { [int]$_.ProcessId })
        }
        catch {
            Log "Instance scan failed (non-fatal): $($_.Exception.Message)"
        }

        # This covers windowed AND windowless sessions (AudioOnly orphans have
        # no window and are invisible to title-based takeover).
        $hadForeign = $false
        try {
            $before = @(Get-ForeignScrcpyProcesses)
            if ($before.Count -gt 0) { $hadForeign = $true }
            Close-ForeignScrcpySessions
        }
        catch {
            Log "Foreign session sweep failed (non-fatal): $($_.Exception.Message)"
        }

        if ($hadForeign -or $otherTuiPids.Count -gt 0) {
            Write-Host 'Another scrcpy-camera-helper instance (or leftover session) was active and has been taken over.' -ForegroundColor Yellow
        }

        foreach ($otherPid in $otherTuiPids) {
            Write-Host "Stopping the previous TUI instance (PID $otherPid)..." -ForegroundColor Yellow
            Log "Commandeering: stopping other TUI instance PID=$otherPid"
            try { Stop-Process -Id $otherPid -Force -ErrorAction SilentlyContinue }
            catch { Log "stopping previous TUI instance PID=$otherPid reported an error: $($_.Exception.Message)" }
        }

        # --- Graceful-exit hardening on every exit path: menu quit, Ctrl+C,
        # an unhandled error, or the console window being closed all end with
        # a safely closed scrcpy (the Win32 handler above covers the last one
        # where no PowerShell code can run anymore).
        Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
            try {
                Stop-Recording -Silent
            }
            catch { Log "exit-path Stop-Recording note: $($_.Exception.Message)" }
            try {
                Stop-Camera -Silent
            }
            catch {
                try {
                    if ($script:State.Pid) {
                        Stop-Process -Id ([int]$script:State.Pid) -Force -ErrorAction SilentlyContinue
                    }
                }
                catch { Log "exit-path force-stop note: $($_.Exception.Message)" }
            }
        } | Out-Null

        # --- Non-interactive start (shortcut/automation path): same machinery
        # as the menu flows, minus the setup prompts.
        if ($AutoStart) {
            $needsAudio = $script:Cfg.Mode -in @('CameraAudio', 'AudioOnly')
            if ($needsAudio -and -not $script:Cfg.AudioTargetId) {
                throw 'AutoStart with an audio mode needs a saved audio output device - run once interactively and pick one with [E] first.'
            }
            if ($script:Cfg.Mode -eq 'RecordOnly' -and $script:Cfg.RecordTarget -eq 'Off') {
                throw 'AutoStart in RecordOnly mode needs a saved recording target - pick one with [K] first.'
            }

            try {
                if ($script:Cfg.Mode -eq 'RecordOnly') {
                    # RecordOnly never starts scrcpy.exe; producers/relays and
                    # FFmpeg are started by Start-Recording itself. It carries
                    # the transition guard, so 'Starting' must NOT be pre-set.
                    $script:State.ProducerV = 'server'
                    $script:State.ProducerA = 'server'
                    Start-Recording
                    Set-TransitionState 'Running'
                }
                else {
                    Set-TransitionState 'Starting'
                    Start-Camera
                    Set-TransitionState 'Running'

                    # mirror of the interactive flow: a configured recording
                    # target starts right away
                    if ($script:Cfg.RecordTarget -ne 'Off') {
                        try {
                            Start-Recording
                        }
                        catch {
                            Log "auto-start recording failed: $($_.Exception.Message)"
                        }
                    }
                }
            }
            catch {
                Set-TransitionState 'Failed'
                Log "AutoStart failed: $($_.Exception.Message)"
                Write-Host "AutoStart failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }

        Menu
    }
    finally {
        try { Stop-Recording -Silent } catch { Log "final Stop-Recording note: $($_.Exception.Message)" }
        Stop-Camera -Silent
        Set-TransitionState 'Stopped'

        try {
            if (Test-Path -LiteralPath $script:TempVbs) {
                Remove-Item -LiteralPath $script:TempVbs -Force -ErrorAction SilentlyContinue
            }
        }
        catch { Log "temp launcher cleanup note: $($_.Exception.Message)" }

        Log "scrcpy-camera-helper exited (v$script:Version)"
    }
}
