# Howl iPhone Hardware Test

Use this on the first real iPhone + Coyote 3 session.

## Goal

Validate four things:

1. BLE handshake works end to end.
2. Live pulse batches actually reach the device.
3. Safety behavior is sane at low power.
4. `Faithful`, `Smooth`, and `Softened` HWL playback feel meaningfully different.

## Before You Start

- Use a real iPhone and a real Coyote 3.
- Start with conservative power only.
- Keep `Channel A` and `Channel B` low for the first pass.
- Have one known-good `.hwl` file ready.

Suggested first-pass power:

- `Channel A`: `5`
- `Channel B`: `5`

## Build And Install

On a Mac:

```bash
cd ios
xcodegen generate
open HowlIOS.xcodeproj
```

Then:

1. Select an iPhone target in Xcode.
2. Build and run the app on device.
3. Allow Bluetooth permission when prompted.

## BLE Handshake Test

In the app:

1. Go to `Settings`.
2. Set output mode to `Live Coyote 3`.
3. Tap `Scan for Coyote 3`.

Expected result:

- `State` should progress to `Ready`.
- `Battery` should populate.
- `Last Write` should mention parameter sync.
- `Last Notify` should stop saying `No notify frames yet.`

If it fails:

- Note the exact `State`.
- Copy `Last Sent Packet`, `Last Notify Frame`, and any red error text.

## Low-Power Live Output Test

1. Stay in `Live Coyote 3`.
2. Keep power low.
3. Load a short `.hwl` file.
4. Press `Play`.

Expected result:

- `Pulse Batches` should increase.
- `Last Sent Packet` should keep changing.
- `Notify Frames` should increase if the device is talking back.
- `Device Echo` should eventually show `A ... / B ...`.
- `Backpressure Hits` can be non-zero, but should not explode upward constantly.

Stop behavior:

1. Press `Stop`.
2. Switch from `Live Coyote 3` to `Preview Only`.

Expected result:

- Output should stop cleanly.
- The device should not appear to keep running the last pattern.

## HWL Profile Comparison

Use the same `.hwl` file for each pass.

Test in this order:

1. `Faithful`
2. `Smooth`
3. `Softened`

For each profile:

1. Load the file.
2. Let it play for at least 20-30 seconds.
3. Note how it feels on:
   - abruptness
   - smoothness
   - loss of punch
   - weird artifacts

What to expect:

- `Faithful`: closest to raw file stepping.
- `Smooth`: likely best default.
- `Softened`: gentler, but may blur sharp motion.

## What To Record

After the session, capture:

- Which HWL profile felt best.
- Whether `Battery` populated.
- Whether `Device Echo` populated.
- Highest observed `Backpressure Hits`.
- Any red BLE error.
- One sample `Last Sent Packet`.
- One sample `Last Notify Frame`.

## Pass Criteria

Call it a good first test if:

- BLE reaches `Ready`.
- Live playback changes the device output.
- Stop/mode-switch silences output correctly.
- At least one notify/status frame is received.
- You can feel a real difference between HWL profiles.

## Failure Signals Worth Fixing Next

- Never reaches `Ready`.
- Packet counters move but device behavior does not.
- `Backpressure Hits` climbs fast and continuously.
- Stop does not silence output.
- `Smooth` and `Softened` feel identical to `Faithful`.
