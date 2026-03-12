# Howl iPhone MVP

This folder contains a native SwiftUI iPhone/iPad prototype for Howl.

What is here now:
- A generator-based Xcode project (`project.yml`) for XcodeGen.
- A reusable `HowlCore` framework for HWL parsing, funscript playback, generator logic, and Coyote packet encoding.
- A SwiftUI app shell with player, generator, activity presets, settings, and BLE discovery scaffolding.
- A GitHub Actions macOS build workflow that can compile the iOS app without you owning a Mac.

What is intentionally not finished yet:
- Verified BLE write/notify handshake for Coyote 2 or Coyote 3 on real hardware.
- Audio-output mode parity with Android.
- Recorder, remote API server, and full activity catalog.

## Generate the Xcode project

On a Mac with Xcode and XcodeGen installed:

```bash
cd ios
xcodegen generate
open HowlIOS.xcodeproj
```

## Current MVP scope

- Load `.hwl`, `.funscript`, and `.json` funscript files from Files.
- Play them through a Swift-native timing loop at 40 pulses/sec.
- Preview real-time pulse values and recent pulse history.
- Build generator-driven output and a few activity-like presets.
- Discover compatible BLE devices and stage Coyote 3 packets for the future transport layer.

## Suggested next steps

1. Finish the CoreBluetooth characteristic discovery and write path for Coyote 3 first.
2. Validate the packet encoder against real hardware with conservative power defaults.
3. Add background behavior only after foreground playback is stable.
4. Decide whether audio-output mode matters enough to justify `AVAudioEngine`.
