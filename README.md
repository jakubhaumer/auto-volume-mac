# auto-volume

System-wide loudness leveler for macOS (14.2+). While it runs, quiet dialogue is boosted and loud
music/effects are pulled down, for every app at once.

## How it works
- A Core Audio **process tap** captures all system audio and mutes the original (no virtual driver needed).
- The audio goes through: slow AGC (steers RMS toward a target) → fast compressor (sudden peaks) → 5 ms lookahead limiter (no clipping).
- The result is played on your current default output device. Switching output devices is handled automatically.
- Ctrl-C (or killing the process) destroys the tap and your normal audio returns.

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
swift run leveler-check                 # DSP self-check
```

Options: `--target <dB>` (default -23), `--max-boost <dB>` (18), `--max-cut <dB>` (20), `--ratio <n>` (3).

## Permission
On first run macOS asks to allow your terminal to record system audio
(System Settings → Privacy & Security → Screen & System Audio Recording). If you deny it, the tap
delivers silence — and since the original is muted, you hear nothing. Grant it and rerun.

## Tuning
- Still too quiet in dialogue: raise `--max-boost` or `--target` (e.g. `-20`).
- Music still jumps out: lower `--target`, raise `--ratio` (e.g. 4–6).
- The system volume slider still applies after processing; set it comfortably and let the tool even things out.

## Limitations
- ~5–10 ms added latency (negligible for video; Bluetooth adds its own).
- Loudness is measured with a simple RMS detector, not full EBU R128 K-weighting.
- Audio from apps macOS excludes from taps (some DRM paths) is not processed.
