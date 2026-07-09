# Experimental features (P3.2 – P3.4)

These are **wired but not validated**. They compile against the iOS SDK and are reachable
behind the Settings → *Experimental features* toggle (default off), but they need a real
iPhone (and, for DockKit, an accessory) to run and prove out. The iOS Simulator has no
Vision body-pose/trajectory model, so none of these do anything useful there.

Nothing here is on the critical path: P1, P2, and the P3 CSV import all work without it.

## P3.2 — 3D setup-frame avatar
- API: `VNDetectHumanBodyPose3DRequest` on the **address frame only**.
- Why setup-frame only: the 3D request is still-image oriented with no temporal smoothing, so
  it jitters badly during the downswing. Do not build motion analysis on it.
- Enable bar: on device, returns a usable 3D observation (>= a sensible joint count) on the
  setup frame of a real clip. If it doesn't, leave it disabled and document the finding.

## P3.3 — Ball flight tracking (high risk)
- API: `VNDetectTrajectoriesRequest` (parabolic, **stationary/tripod camera required**).
- Club-head tracking is intentionally **not implemented**: the club head moves on an arc, not a
  parabola, so it needs a custom Create ML object detector + labeled data + a device spike.
- Enable bar (spike-first, from the design): ball detected in **>= 70%** of tripod clips with
  acceptable precision/recall. Record the numbers. Ship only if it clears the bar; otherwise
  shelve with written findings.

## P3.4 — DockKit motorized stand
- API: `DockKit` (guarded with `#if canImport(DockKit)`), no-op without a paired accessory.
- Enable bar: validated manually with the physical gimbal.

## How to validate on device
Connect an iPhone, set signing (team already configured), then:

```
xcodebuild -project swing-analyzer/ios/GolfSwingAnalyzer.xcodeproj \
  -scheme GolfSwingAnalyzer \
  -destination 'platform=iOS,name=<your iPhone>' test
```

The device-gated XCTests (currently `XCTSkip` on the Simulator) run for real there.
