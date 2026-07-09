# Divot

On-device golf swing analysis for iPhone. SwiftUI over a validated Swift package
(`SwingCore`) that uses Apple Vision + AVFoundation to detect swing events, measure
faults against club-aware benchmarks, and compare your motion to bundled pro references.

Everything runs on the device. Your video never leaves the phone, and there are no
accounts, servers, or cloud calls.

## Requirements
- Xcode 26+ / iOS 26 SDK
- An iPhone for full functionality (the Simulator has no camera or body-pose model)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build
```sh
make bootstrap        # installs tools + generates the Xcode project
open ios/Divot.xcodeproj
```
On-device builds need a signing team: copy `ios/Config/Signing.local.template.xcconfig`
to `ios/Config/Signing.local.xcconfig` and set your `DEVELOPMENT_TEAM`. The Simulator
builds without signing.

## Validate
```sh
make validate         # engine golden checks (headless):  ALL PASS, 176 checks
make test             # simulator: unit + accessibility audit + screenshot tour
make device-test DEVICE=<udid>   # full on-device suite (Vision, ball-flight, haptics)
```

## Layout
- `SwingCore/` — the platform-agnostic analysis engine (Swift package) + its headless self-check.
- `ios/` — the SwiftUI app (consumes `SwingCore` as a local package).
- `tools/` — dev utilities (e.g. the synthetic test-clip generator).

## License
Copyright (c) 2026 Roman Bisecke. All rights reserved.

This source is published for viewing only. No license is granted to use, copy, modify,
or distribute this code, except for the view-and-fork rights automatically granted to
GitHub users under GitHub's Terms of Service.
