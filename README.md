# screenrec

`screenrec` is a command-line tool for macOS that records every connected display as a video file, each with the system audio. It was written to record lectures: start it in a terminal before the lecture, stop it with Ctrl-C afterwards.

- One `.mov` file per display (HEVC video, AAC audio), plus a `.json` file with timestamps for synchronizing the recording with other sources.
- It does not change any audio or video device. The sound keeps playing through whatever output is selected, for example HDMI to the lecture hall. Camera and microphone are never opened.
- If a display is plugged in or unplugged, or a capture stream fails, the affected file is finalized and a new one begins. The recording does not stop.
- A single Swift file without dependencies. It uses ScreenCaptureKit and runs on macOS 13 and later, on Apple Silicon and Intel.

## Build

```
./build.sh
```

This needs `swiftc` from the Xcode Command Line Tools (`xcode-select --install`). The result is the universal binary `screenrec` (arm64 and x86_64, deployment target macOS 13). You can copy the binary to another Mac.

## Usage

```
./screenrec --list                      # print the detected displays
./screenrec -o ~/Recordings -p lecture  # record, stop with Ctrl-C
```

Stop with Ctrl-C, SIGTERM or SIGHUP (closing the terminal window). `screenrec` then finalizes the files, which takes one to two seconds. Each display yields `<prefix>_<date>_displayN.mov` and a `.json` file of the same name.

The files go to the directory given with `-o`, or to the current directory. The directory is created if it does not exist.

| Option | Meaning | Default |
|---|---|---|
| `-o, --out DIR` | output directory | current directory |
| `-p, --prefix NAME` | file name prefix | `rec` |
| `--fps N` | maximum frame rate | 15 |
| `--max-height N` | limit the frame height, keeping the aspect ratio; 0 = native | 1080 |
| `--scale F` | fixed scale relative to the native resolution, replaces `--max-height` | – |
| `--codec hevc\|h264` | video codec | `hevc`, or `h264` if the Mac has no hardware HEVC encoder |
| `--bitrate KBPS` | video bit rate | estimated from resolution and fps |
| `--no-cursor` | do not record the mouse pointer | – |
| `--allow-sleep` | do not keep the Mac awake while recording | – |

## Permission

macOS asks for the permission "Screen & System Audio Recording" (called "Screen Recording" before macOS 15) under System Settings > Privacy & Security. The permission belongs to the app that `screenrec` is started from, such as Terminal or iTerm, not to `screenrec` itself. After granting it, quit and restart that app.

Since macOS 15 the system asks again from time to time. Run `./screenrec --list` once before anything important, so that the question does not come up when the recording should start.

## Displays and interruptions

- Extended desktop: one file per display, each with the same system audio track. `display0` is the main display at the time the file starts.
- Mirroring: one file. Displays that show the same area as another display are skipped, and `--list` reports them as "not recorded".
- `screenrec` records displays, never single windows.

Every 2 s, and immediately after a stream failure, `screenrec` compares the running recordings with the displays that are present:

- If a stream fails (an error, a crash of the system service, or the recording being stopped from the menu bar), the file is finalized and a new one begins for the same display. The measured gap was 0.4 s.
- If a display is unplugged, its file is finalized. The other recordings continue.
- If a display is plugged in, or switched from mirroring to extended, a new file begins for it.
- If a restart fails, for example because the disk is full, `screenrec` tries again every 2 s and prints the message once.

Each new file has a new time in its name and its own `.json` file, so the parts can be placed on a common timeline.

### Sleep

While recording, `screenrec` keeps the Mac from going to sleep and from turning off the display due to inactivity, like `caffeinate -di`. It changes no setting, and the effect ends with the program. Closing the lid and the menu command "Sleep" still work. `--allow-sleep` turns this off.

## Audio

- `screenrec` records what the Mac plays, as AAC with 48 kHz stereo. The audio is taken before the volume control, so the volume setting of the Mac does not change the level in the recording.
- The output device stays as it is.
- Whether a muted Mac still yields sound in the recording has not been tested.

## Video

- The frame rate is variable. ScreenCaptureKit delivers a frame only when the screen changes, at most `--fps` per second. A static screen produces no frames, which keeps the files small. Editing software that expects a constant frame rate needs a conversion first: `ffmpeg -i in.mov -vf fps=30 -c:a copy out.mov`.
- The frame rate does not have to match a camera that is recorded in parallel. With a 30 fps camera, 15 or 30 fps work well, because every screen frame then coincides with a camera frame.
- Colors are sRGB, tagged as BT.709, 8 bit. P3 and HDR content is converted to sRGB. True Tone and Night Shift take effect in the display and are not part of the recording.
- When stopping, `screenrec` writes the last frame once more, so that with a static screen the video track is as long as the audio track.
- The file is written in fragments of 10 s. After a crash it is readable up to the last fragment. The first 10 s of a file are not protected yet.

## File size

One real lecture recording, 3 h 34 min at 1920×1080 with mostly static content (4.4 frames per second on average) and a nearly silent audio track, came to 275 MB.

Measured with terminal content at Full HD, HEVC and 15 fps, the video takes 0.7 to 1.2 Mbit/s, which is 0.3 to 0.55 GB per hour and display. Audio adds at most 0.07 GB per hour. A full-screen video needs considerably more. The upper limit in the tests, full-screen noise, was 6 Mbit/s or 2.7 GB per hour.

## Synchronizing with other sources (.json file)

The `.json` file is written with the first frame and updated when the recording stops.

| Field | Meaning |
|---|---|
| `file` | name of the video file |
| `file_t0_host` | time of the first frame (time 0 of the file) on the host clock, in seconds. This is the clock behind `time.monotonic()` in Python on macOS |
| `file_t0_unix` | the same instant as Unix time |
| `first_audio_host` | time of the first written audio buffer on the host clock. It can lie a few milliseconds before `file_t0_host`; the part before is cut off |
| `display_index`, `display_id`, `width`, `height`, `max_fps`, `codec` | recording parameters |
| `video_frames`, `video_frames_dropped`, `audio_buffers_dropped` | counters |
| `finalized` | `true` if the file was closed properly |

An event logged at `time.monotonic() == t` on the same Mac is found at `t - file_t0_host` seconds in the file. The host clock stands still during sleep and starts again after a reboot. To align recordings from two computers, use `file_t0_unix` or the audio track.

## Why not ffmpeg, OBS or `screencapture`?

- ffmpeg with `avfoundation` captures the screen through `AVCaptureScreenInput`, which is deprecated since macOS 15. It gets system audio only through a virtual device such as BlackHole combined with a multi-output device. That changes the audio routing and takes away the volume control.
- `screencapture -v` records the microphone, not the system audio.
- `SCRecordingOutput`, the recording API that Apple added to ScreenCaptureKit, requires macOS 15.
- OBS works, but it is a large application and awkward when the number of displays changes between one and two.

## Tests

Measured on a MacBook Pro (M4 Pro, macOS 26.6.2) with one display of 3600×2338 pixels, recording at 1662×1080, HEVC, 15 fps.

| Test | Result |
|---|---|
| Build | arm64 and x86_64 without warnings, `minos 13.0`. The x86_64 half runs under Rosetta (`--list`) |
| 60 s with a click signal played by `afplay` | HEVC `hvc1` and AAC 48 kHz stereo, 61.4 s, no frame and no audio buffer dropped |
| Audio track against the source | unambiguous cross-correlation, same level as the source (peak 16057 vs. 15973), drift of 12 samples in 40 s |
| CPU, static screen | about 1 % of one core |
| CPU, moving full-screen content | 3 to 4 % for `screenrec`, 2 to 3 % for the system service `replayd`, 14.8 fps |
| `kill -9` after 27 s | file readable, 20 s of video and audio |
| Ctrl-C during startup | before the first stream the program exits at once (exit code 130), after that it leaves a clean file |
| Audio devices before and after | `system_profiler SPAudioDataType` identical |
| Timestamps | a screen change appears 14 to 60 ms after the `time.monotonic()` logged in Python, at a frame interval of 67 ms |
| Colors | sRGB patches arrive within ±1 (red 255/1/0, gray 128/128/128) |
| Stream failure (system service `replayd` killed) | first file finalized, new file after a gap of 0.36 s |
| Disk full (15 MB test image) | one error message, retries every 2 s, Ctrl-C exits cleanly |
| stderr closed, then SIGTERM | file finalized properly |
| Static screen before stopping | video track 10.08 s, audio track 10.05 s |
| Reconciliation every 2 s | no measurable extra load |

The moving content was a test window with 400 random rectangles at 60 Hz, not a video.

### Not tested yet

- Two displays in extended mode, and unplugging or replugging one of them while recording.
- Mirroring, and switching between mirroring and extended mode while recording.
- Sending a single window to the second display (window mirroring).
- Macs with macOS 13 to 15, and Intel Macs. On Intel the first log line shows whether HEVC or H.264 was chosen.
- A muted Mac.
- The error message for a missing permission.

Reports on any of these are welcome as issues.

## License

MIT, see [LICENSE](LICENSE).

Developed at the [Chair of Privacy and Security in Information Systems](https://www.uni-bamberg.de/psi/) (PSI), University of Bamberg.
