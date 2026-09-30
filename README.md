# scrcpy-camera-helper

Use your Android phone as a **camera**, **microphone**, or **recorder** for
your Windows PC. Apps like OBS, Discord, Zoom, Teams, browsers, and audio
editors can then use the phone's picture and sound as if they came from a
regular webcam and microphone.

The heavy lifting is done by [scrcpy](https://github.com/Genymobile/scrcpy). Everything runs locally on your PC —
no accounts, no sign-ups, no cloud services.

## Demo

[Watch the guided session](docs/demo.mp4) (~47 s, silent) — start-up, guided
setup, going live with the phone's camera and microphone, recording, and a
clean stop.

<!-- Maintainer note: GitHub renders the in-repo MP4 with a player on its
     file (blob) page. For fully inline playback inside the README itself,
     attach the MP4 once in a GitHub markdown editor and replace the link
     above with the resulting user-attachments URL. -->

## What you need

- **Windows 10 or 11.**
- **PowerShell 7** — a free Microsoft download. Install it from any terminal
  with: `winget install Microsoft.PowerShell`
  (If you start the app without it, the launcher tells you this and stops.)
- **An Android phone** connected with a USB cable, with **USB debugging**
  turned on:
  1. On the phone, open *Settings → About phone* and tap **Build number**
     seven times to unlock Developer options.
  2. In *Settings → System → Developer options*, enable **USB debugging**.
  3. Connect the phone, unlock it, and tap **Allow** on the
     "Allow USB debugging?" popup.
  - Microphone modes need **Android 11 or newer**; camera modes need
    **Android 12 or newer**.
- **For live microphone sound:** a free virtual audio cable such as
  [VB-CABLE](https://vb-audio.com/Cable/). A virtual cable is a fake sound
  card: audio played *into* it can be recorded *from* it by another app.
  That is how the phone mic reaches OBS and friends.
- **For recording to files:** [FFmpeg](https://ffmpeg.org/download.html)
  installed. (Using the camera or microphone live does not need it.)

## Start here

Double-click **`scrcpy-camera-helper.cmd`**. A console window with a text
menu opens.

Press **`1`** (Start) for the guided setup. It walks you through explicit
steps — nothing is silently reused until you have seen and accepted it:

1. **Mode** — `V` (camera only), `B` (camera + mic), `S` (sound only) or
   `F` (record only). An explicit letter is required; Enter alone never
   picks anything here.
2. **Rotation** (camera modes) — Enter keeps the current value.
3. **Live camera settings** (camera modes) — the current camera, resolution,
   frame rate and bitrate are shown; press Enter to keep them, or `N` to walk
   through lists negotiated with the phone in real time (only options your
   device truly supports).
4. **Audio device** (modes with a mic) — a searchable device picker opens.
   The usual choice is the virtual cable's input, e.g. *CABLE Input*.
5. **Record too?** (live modes) — a plain yes/no; record-only implies yes.
   - For **Live + Recording** the setup is deliberately two stages: first the
     live settings, then `Press Enter to continue to recording settings`
     opens the second stage.
6. **Recording settings** — target, container, quality and folder are shown;
   press Enter to keep them, or `N` to open the full settings page. If nothing
   recordable is configured yet, the flow makes you pick a target on the spot.
7. **Confirm** — a closing summary is acknowledged with
   `Press Enter to confirm settings`, then one go/no-go question worded for
   exactly what is about to happen: **Are you ready to go live?**,
   **Are you ready to record?**, or **Are you ready to go live and record at
   the same time?** `Yes` starts it and returns you to the main screen.

To change it later: the mode keys (`V`/`B`/`S`/`F`) in the menu switch
directly at any time, each running the same guided steps for the parts it
needs. For fully hands-free starts, see the command-line options below.

Your choices are saved automatically in `scrcpy-camera-helper.settings.json`
(right next to the app) and restored on the next launch. Delete that file if
you ever want to start over with the defaults.

### Starting from a shortcut or the command line
`scrcpy-camera-helper.cmd` accepts optional arguments, so a desktop shortcut
or a scheduled task can jump straight in without answering anything:

```
scrcpy-camera-helper.cmd -Mode CameraOnly -AutoStart
scrcpy-camera-helper.cmd -Mode AudioOnly -Rotation 90 -AutoStart
```

- **`-Mode`** — `CameraAudio`, `CameraOnly`, `AudioOnly`, or `RecordOnly`.
- **`-Rotation`** — `0`, `90`, `-90`, `180`, or `-180` degrees.
- **`-AutoStart`** — start the session immediately (no prompts), then drop
  into the normal menu. Notes: audio modes need a device picked once with `E`
  first; RecordOnly needs a target set once with `K` first.

## How it works (30-second mental model)

- **Camera:** the app opens a real video window titled **scrcpy OBS Camera**,
  but parks it off-stage — under all other windows or at the screen edge — so
  you never have to look at it. Capture software such as OBS grabs that
  window by its title.
- **Microphone:** the phone's mic sound is played by the app into one Windows
  playback device you choose, normally the virtual cable's input. Other apps
  then "listen" to the cable's output side. Only this app's sound is
  redirected; the rest of your system audio is untouched.
- **Recording:** FFmpeg saves the phone's video and/or audio straight to a
  file on disk.

## Modes

Press the mode key at any time; the session restarts itself with the new
mode. The exception is an active recording: mode changes restart the live
capture, so they are refused until the recording is stopped (the menu says
exactly how). The current mode is always shown at the top of the menu.

| Key | Mode | What you get |
|---|---|---|
| `B` | Camera + mic | video window plus phone microphone audio |
| `V` | Video only | camera picture, no audio anywhere |
| `S` | Sound only | phone mic only — no window is created at all |
| `F` | Record only | no live window; a file is written when you press `G` |

- **Camera + mic (`B`)** is the everyday mode: picture and sound together.
- **Video only (`V`)** is the quietest option for your system — no audio
  stream exists at all, which some OBS setups prefer.
- **Sound only (`S`)** turns the phone into a plain PC microphone; nothing
  appears on screen, so there is nothing for OBS to grab as video.
- **Record only (`F`)** skips the live view entirely — useful when all you
  want is a file.

## Main menu at a glance

**Live** and **Recording** are independent operations, and the menu's Session
section always spells out exactly what each stop key ends:

- **Stopped:** `1` Start (guided, step-by-step) · `Q` Quit
- **Live Only:** `G` Start recording · `2` Stop Live · `3` Restart live
- **Live + Recording:** `G` Stop Recording (live stays on) · `T` Stop Live
  (recording keeps going) · `2` Stop Both
- **Recording Only:** `G` Stop Recording

**`Q` (Quit)** is deliberately **not** a stop button: while anything is
running it only explains what is active and which key stops it. Once neither
Live nor Recording is active, `Q` quits normally.

- **Live modes:** `V` `B` `S` `F` (direct switch, no cycling)
- **Recording:** `G` start/stop · `K` recording settings
- **Camera + audio:** `C` camera settings · `E` audio output device ·
  `R` re-apply audio route
- **Rotation:** `0` 0° · `9` +90° · `N` −90° · `8` +180° · `7` −180°
- **Advanced:** `4` window parking · `5` diagnostics · `6` run scrcpy in a
  visible window · `?` help screen

The top of the menu is a status card that leads with **OPERATION**
(`Stopped`, `Live Only`, `Recording Only`, or `Live + Recording`) and then one
line each for the **LIVE** and **RECORDING** sources (`Camera Only`,
`Audio Only`, or `Camera + Audio`). When both operations run, each keeps its
own line even if they use different sources. Below that: session state,
rotation, audio output, camera settings, parking style, and what OBS sees —
updated immediately after every action.

## Camera

### Rotation — `0` `9` `N` `8` `7`
Rotates the camera picture: 0°, +90°, −90°, +180°, or −180°. Two things stay
constant on purpose: the window title (**scrcpy OBS Camera**) and the window
size (1920×1080). Rotated video is letterboxed inside that fixed frame, so a
capture source in OBS stays attached and correctly sized — you can rotate
mid-stream without touching OBS.

### Camera settings — `C`
Opens a page with five entries. Every list shown here is read live from your
phone, so you only ever see options your device genuinely supports — nothing
is guessed:

1. **Camera** — choose between the phone's cameras (back, front, and any
   extras the phone reports).
2. **Resolution** — pick from every size the camera supports.
3. **Frame rate** — standard rates, plus high-speed frame rates where the
   phone offers them for the chosen resolution; the phone's high-speed
   capture mode is enabled automatically when you pick one.
4. **Bitrate** — how much data per second the video gets (higher = sharper,
   smoother motion). Only values inside the range the phone's encoder chip
   reports as valid are accepted.
5. **Restore all camera defaults** — one key back to the proven defaults.

Changes apply by restarting the camera session, so the picture flickers once
and returns with the new settings.

### The parked window — `4`
The camera window must stay open while you use it, but you never have to look
at it. Two parking styles:

- **Underlay** — the window is pushed to the very bottom of the window
  stack, behind everything else.
- **EdgeAnchor** — the window is tucked against the edge of the screen,
  almost entirely out of view.

Press `4` to toggle between them. Do not close the window yourself — use
`2` (Stop) instead.

## Microphone

### What you get
The phone's microphone is captured with its **raw, unprocessed** signal: no
automatic gain control, no echo cancellation, and no noise suppression is
added on the way. What the phone hears is what your apps receive — ideal if
you prefer to shape the sound yourself in your editor or streaming app.
Audio travels uncompressed, so no quality is lost in transit.

### Where the sound goes — `E`
Press `E` to open the device picker: a searchable list of every active
Windows playback device. Start typing to filter (e.g. "cable"), pick the
device, done. The choice is remembered for future sessions.

The usual choice is the **virtual cable's input**. Because a virtual cable
loops audio from its input to its output, any app that records from the
cable's *output* hears the phone mic.

Only the sound produced by this app is redirected to that device. Your
speakers, headset, music players, and every other application stay exactly
as they were — you will not suddenly hear the phone mic yourself.

### Switching while live
Picking a different device with `E` while a session is running moves the
live audio to the new device without restarting anything. If Windows ever
forgets the routing (for example after the device was unplugged and
reconnected), press `R` to re-apply it to the running session.

## Recording — `G` and `K`

Recording is done entirely by FFmpeg, so files are always written and
finalized properly — an interruption never leaves a corrupt half-file.

### Start and stop
- Press **`G`** to start. The menu shows that recording is running, with the
  file name.
- Press **`G`** again to stop. The file is finalized cleanly and ready to
  use.
- Files are named `rec-YYYYMMDD-HHMMSS.mkv` (or `.mp4`) — a timestamp, so
  files never overwrite each other.

While a recording runs, quitting stays blocked so a file is never lost, and
changing recording or live settings goes through deliberate gates: `K` offers
a stop-and-resume path for recording settings, while mode/rotation/camera
changes explain that the recording must be stopped first.

### Recording settings — `K`
1. **Target** — what to capture: `Off`, `Video`, `Audio`, or `VideoAudio`
   (both).
2. **Output** — save recordings next to the app, or choose your own folder.
3. **Container** — `mkv` (default) or `mp4`. Choose `mkv` if there is any
   chance of interruption, because it survives crashes; choose `mp4` when
   you need to hand the file to something picky about formats.
4. **Video preset** — how the picture is stored:
   - **Copy** (default): keep the phone's video exactly as it arrives — no
     re-encoding, instant, lossless, lowest CPU cost.
   - **Balanced / HighQuality / StorageEfficient**: re-encode while
     recording, trading CPU time for a different size/quality balance.
   - **Custom**: your own settings via item 8.
5. **Audio codec** — `Copy` (store as-is), `AAC` (plays everywhere), `Opus`
   (great quality at low bitrates), `FLAC` (lossless), `PCM` (uncompressed,
   biggest files).
6. **Audio bitrate** — quality setting for the lossy codecs (AAC/Opus);
   ignored otherwise.
7. **Video bitrate** — target bitrate when re-encoding; limited to the range
   your phone's encoder reports.
8. **Custom FFmpeg arguments** — extra FFmpeg options for advanced users;
   the app validates them before accepting them.
9. **FFmpeg location** — detected automatically in most setups; point to
   `ffmpeg.exe` yourself here if needed.
0. **Disconnect behavior** — what happens if the phone is unplugged while a
   recording runs (see below).
- **`D`** restores all recording defaults.

### If the phone disconnects mid-recording
USB cables get bumped. The behavior is chosen as part of every recording setup
(the guided start asks it; `K` shows it as item `0` and asks too):

- **Placeholder** — the recording keeps running in the same file. While the
  phone is away, the file receives black video frames and silence; when the
  phone returns, real picture and sound continue in the same file.
- **Split** — the current file is finalized cleanly the moment the phone
  disconnects, nothing is recorded while it is away, and a brand-new file
  begins when the phone returns. If you were also live, the preview and mic
  playback return automatically when the phone returns.

Either way, pressing `G` (Stop) is always the proper way to end a recording.
When you stop after a bumpy session, the app offers to tidy up — removing
placeholder stretches or merging split files into one; just follow the
on-screen prompt.

### Changing camera settings while live — `C`
Press `C` any time — even while live. The screen walks you through the same
phone-negotiated steps (camera → resolution → frame rate → bitrate). Each
change restarts the session for you; the OBS source stays attached because the
window keeps the same title and size — it just blinks for a heartbeat.
(While a recording is running, camera and rotation changes are refused —
restarting the producer would cut frames out of the file. Stop the recording
first; the menu tells you which key does that.)

### Changing recording settings while recording — `K`
Press `K` any time. If a recording is running, the app tells you plainly:
stopping the recording is needed to change its settings, and **you stay live
— only the file recording stops**. Confirm, adjust the stepped settings
(target → folder → container → video preset → audio codec), and optionally
start recording again right away.

### Stopping operations independently
Live and recording never stop as a side effect of each other:

- `G` **Stop Recording** finalizes the file; if you were live, the preview
  and audio keep running (status drops to *Live Only*).
- `T` **Stop Live** closes the preview and mic playback, but a running
  recording keeps writing (status drops to *Recording Only*). This works
  because while recording, production always runs on the phone itself and the
  live view is just an optional viewer of that same stream.
- `2` **Stop Both** (shown while both run) finalizes the file first, then
  closes the live session (status returns to *Stopped*).

`G` when idle starts a recording with the configured target — in a live mode
it records alongside, in record-only mode it is the main action.

## Using it in OBS

1. Add a **Window Capture** source and set its window to
   **scrcpy OBS Camera**. Inside that source's properties, keep
   *Capture Audio* turned **off**.
2. Add an **Audio Input Capture** source and set its device to the cable's
   output side (for VB-CABLE that is *CABLE Output*).
3. Talk into the phone — the OBS mixer levels for the audio source should
   move, and the video source shows the camera picture.

In other apps (Discord, Zoom, Teams, browsers): open their audio settings
and pick the cable's output as the microphone.

## A few don'ts that save you time

- **Do not** enable Windows' "Listen to this device" for the cable — it
  creates a second, echoing path for the same audio.
- **Do not** monitor OBS output back into the cable's input — the mic gets
  doubled.
- If an audio editor refuses to open the cable, use **mono, 48 kHz, 32-bit
  float** in that app's device settings, then make the app rescan audio
  devices.

## Troubleshooting

- Press **`5`** (Diagnostics) for a snapshot of everything the app can see:
  the phone connection, versions, audio route, and recording state.
- Press **`6`** to run scrcpy in a normal visible window — if the picture
  works there, the app's own setup is fine and the issue is in your capture
  software.
- Phone connected but nothing starts? Unlock it and approve the
  USB-debugging popup, then try again.
- More than one phone connected? The app asks you to pick one at start.
- A running log is kept in `scrcpy-camera-helper.log` in this folder — the
  first place to look when something misbehaves.
- To reset everything, stop the app and delete
  `scrcpy-camera-helper.settings.json`; the defaults are recreated on the
  next launch.

## Safety nets

- If a previous copy of the app (or a leftover phone session) is still alive
  when you launch, the new launch politely shuts it down and takes over —
  nothing gets stuck.
- Every way out — Quit, Ctrl+C, closing the console window, even signing out
  of Windows — stops the phone session cleanly. Nothing is left running on
  the phone or the PC.

## License

GNU AGPL v3 or later — see `LICENSE`.
