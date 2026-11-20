# auto-volume

System-wide loudness leveler for macOS (14.2+). While it runs, quiet dialogue is boosted and loud
music/effects are pulled down, for every app at once.

## How it works
- A Core Audio **process tap** captures all system audio and mutes the original (no virtual driver needed).
- Loudness is measured the broadcast way (ITU-R BS.1770 K-weighting). A slow loop steers programme loudness
  toward a target; speech pauses freeze the gain so it never creeps up between phrases; a fast guard retracts
  boost the instant a loud event starts; a true-peak lookahead limiter (-2 dBTP) catches the rest.
- Small loudness differences are corrected slowly (natural speech emphasis survives), big ones quickly.
- The result is played on your current default output device. Switching output devices is handled automatically.
- Quitting (or killing the process) destroys the tap and your normal audio returns.
- Every parameter is traced to a standard, a paper or a measurement: see [docs/RESEARCH.md](docs/RESEARCH.md).

## The app (recommended)
`Auto Volume` lives in your menu bar: a live graph of original vs leveled sound, how many dB it is
boosting or calming, four modes (Gentle / Balanced / Strong / Night), on/off switch and "Open at login".
Left-click the menu bar icon for the panel, right-click for a quick menu.

```sh
scripts/make-dmg.sh     # builds dist/AutoVolume-<version>.dmg (drag the app to Applications)
scripts/build-app.sh    # builds just dist/Auto Volume.app
```
First launch asks for permission to capture system audio — click Allow. The app is ad-hoc signed
(not notarized), so on *another* Mac use right-click → Open the first time.
For a prettier DMG window, allow Terminal to control Finder when macOS asks while running `make-dmg.sh`.

## Command line tool
## Build & run
```sh
swift build -c release
.build/release/auto-volume              # start leveling
.build/release/auto-volume --verbose    # print live level/gain each second
.build/release/auto-volume --bypass     # A/B: same path, no processing
swift run leveler-check                 # standards (EBU Tech 3341) + behaviour checks
```

Options: `--target <LUFS>` (default -19), `--max-boost <dB>` (18), `--max-cut <dB>` (20), `--zone <dB>` (1),
`--ratio <n>` (30; 1 = off).

## Permission
On first run macOS asks to allow your terminal to record system audio
(System Settings → Privacy & Security → Screen & System Audio Recording). If you deny it, the tap
delivers silence — and since the original is muted, you hear nothing. Grant it and rerun.

## Tuning
- Still too quiet in dialogue: raise `--max-boost` or `--target` (e.g. `-17`).
- Music still jumps out: lower `--target`; in the app choose **Strong** or **Night**.
- Want it barely there: choose **Gentle**; only big differences are corrected.
- The system volume slider still applies after processing; set it comfortably and let the tool even things out.

## Limitations
- Adds ~28 ms of delay (13 ms Core Audio buffer + 15 ms DSP lookahead). Bluetooth adds its own.
- A real-time leveler cannot know a loud scene is coming: after a sudden loud scene it is back within ~3 dB after
  roughly 7 s (about 3-5 dB over target during the first seconds). Making that faster audibly damages speech
  dynamics (measured, see docs/RESEARCH.md §6).
- Whispered dialogue below about -50 LUFS is left alone so room noise is never boosted.
- Audio from apps macOS excludes from taps (some DRM paths) is not processed.
