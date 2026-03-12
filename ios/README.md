# Howl iPhone MVP

This folder contains a native SwiftUI iPhone/iPad prototype for Howl.

What is here now:
- A generator-based Xcode project (`project.yml`) for XcodeGen.
- A reusable `HowlCore` framework for HWL parsing, funscript playback, generator logic, and Coyote packet encoding.
- A SwiftUI app shell with player, generator, activity presets, settings, and a first-pass Coyote 3 BLE transport plus hardware-test diagnostics.
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
- Re-render HWL files through selectable `Faithful`, `Smooth`, and `Softened` playback profiles.
- Discover a Coyote 3, subscribe to its notify channel, sync parameters, poll battery, and send Android-shaped 4-pulse live packets.
- Inspect the current preview packet, last transmitted packet, notify summaries, device-echoed power, and BLE backpressure counts during testing.

## Suggested next steps

1. Validate the Coyote 3 handshake and 4-pulse live writes against real hardware with conservative power defaults.
2. Decide whether the current "keep latest batch" backpressure strategy is enough, or whether we need a deeper transmit queue.
3. Decide whether Coyote 2 support is worth the extra protocol surface.
4. Add background behavior only after foreground playback is stable.
