# GolfSwingAnalyzer — Xcode setup

> ✅ **Status: builds and is tested.** Compiles and links against the iOS 26.5 SDK
> (`** BUILD SUCCEEDED **`), and the XCTest suite is green on the iPhone 17 Simulator
> (3 passed, 1 skipped). The skipped one is the full Vision pipeline, which the
> Simulator can't run (no body-pose model); it is validated instead on macOS against
> golden fixtures via `SwingCore/validate.sh`, including the exact clip this app
> bundles, and it runs for real on a device / a signed Mac run. See **Validation** below.

## Requirements
- **Xcode 16+** (built with 26.6), **iOS 18+** iPhone, a free Apple ID (no paid account needed).
- Everything runs on-device. Videos never leave the phone.

## The project
The Xcode project is generated from `ios/project.yml` by **XcodeGen** and is committed,
so you can open it directly:
```
open swing-analyzer/ios/GolfSwingAnalyzer.xcodeproj
```
If you change `project.yml` (or add/remove files), regenerate with:
```
brew install xcodegen   # once
xcodegen generate --spec swing-analyzer/ios/project.yml --project swing-analyzer/ios
```
The project already: targets iOS 18, links the local **SwingCore** package (which bundles
the 8 pro reference templates), and includes the `GolfSwingAnalyzerTests` suite.

**To run on your iPhone**, set signing: target → Signing & Capabilities → *Automatically
manage signing* → pick your personal Team. (Bundle id defaults to `com.golfswing.app`.)

## Info.plist
No special permissions are required: `PhotosPicker` and the Files importer both work
without a usage-description string. (If you later switch to the classic photo-library
API, add `NSPhotoLibraryUsageDescription`.)

## Build & run to your iPhone
- Plug in the phone, select it as the run destination, press **▶**.
- First launch on device: Settings → General → VPN & Device Management → trust your
  developer certificate.
- **Free provisioning expires after 7 days** — re-build from Xcode to refresh, or set up
  **SideStore** (per the brainstorm doc) to auto-refresh over Wi-Fi.

## Using it
1. **Analyze tab** → choose a swing video (Photos or Files) → set Club + Angle → **Analyze**.
   Pose detection + metrics run on-device (~1–3 s for a short clip).
2. **Results**: session focus, match-to-pro %, faults with cues/drills, measurements vs
   targets, and **Compare to the pro** → the ghost overlay (your yellow skeleton + the
   green pro ghost, event-aligned, at address/top/impact/finish).
3. **History tab**: every saved session (video kept in the app sandbox). Swipe to delete.
4. **Settings tab**: handedness + defaults.

## Validation

Run the test suite on a Simulator (compiles the app + engine against the iOS SDK and
runs the app-layer tests):
```
xcodebuild -project swing-analyzer/ios/GolfSwingAnalyzer.xcodeproj \
  -scheme GolfSwingAnalyzer \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test
```
Green result: 3 pass (SwiftData persistence round-trip, 8 pro templates bundled and
loadable in-app, club-aware benchmarks), 1 skipped.

The skipped test is `testPipelineRunsOnDevice`: `VNDetectHumanBodyPoseRequest` returns
nothing on the Simulator, so the end-to-end pose run can't execute there. Two ways to
run it for real:
- **On your iPhone**: set signing (above), plug in the phone, pick it as the destination,
  and run the same `test` command. The skip lifts and the pipeline is exercised in-app.
- **Signed "Designed for iPad" Mac run**: sign in to Xcode with your Apple ID once
  (Xcode → Settings → Accounts) to get a free development certificate, then
  `-destination 'platform=macOS,variant=Designed for iPad'`. Vision works fully there.

The pose→events→metrics→faults→comparison math itself is already validated exactly on
macOS (`bash swing-analyzer/SwingCore/validate.sh`, 49 checks) against the laptop CLI's
golden fixtures, so the device/Mac run is confirming the *same code* executes in-app.

## Where the real work lives
The app is a thin shell. All analysis is `SwingCore`:
- `SwingAnalyzer.analyzeSession(video:club:angle:hand:)` → `Session`
- `FaultEvaluator.benchmarks(club:)` → per-metric targets for the Results screen
- `ReferenceStore` + `TemplateBuilder` + `PoseComparator` → the ghost overlay
These are covered by `SwingCore/validate.sh` against the laptop CLI's golden fixtures.
