# Divot — Fix Design Doc

Companion to `claude_docs/code-review-findings.md`. Every fix below was designed against the
actual current source (not guessed), matching the codebase's existing idioms rather than
introducing new ones: SwingCore's tests live in `SwingCoreCheck/main.swift` as `check()`/`approx()`
calls grouped into `[Bracket]` sections, not XCTest; the iOS app's pure-logic helpers (`framing`,
`nextPosition`) get plain XCTest cases; concurrency stays queue-based (no Combine, no new actors
beyond what's already there). Finding numbers below match `code-review-findings.md` exactly.

Nothing here has been implemented. This is the plan.

## Validation tiers (recap from CLAUDE.md)

- **T1** — `make validate` (SwingCore's headless `SwingCoreCheck` harness). Prints
  `ALL PASS, N checks` today, though per finding #1, `N` is currently much smaller than it should
  be because most fixture-gated sections silently skip. Fixing #1 changes `N`; every other SwingCore
  fix below adds to it further. **CLAUDE.md's documented check count needs updating once these land**,
  and again after each subsequent addition — treat the printed count as ground truth, not something
  to hand-compute.
- **T2** — `make test` (Simulator XCTest: unit + accessibility audit + screenshot tour). Currently
  56 unit + 4 device-skipped + 2 UI, 0 failures. Several fixes below add unit tests; update the
  documented count accordingly.
- **T3** — `make device-test DEVICE=<udid>` (real iPhone; camera, Vision, haptics, 240fps). Most of
  the capture-layer concurrency/orientation fixes are only meaningfully verifiable here, since the
  Simulator has no body-pose model and no real `AVCaptureSession`.

## Cross-cutting dependencies (read before starting)

A few fixes below touch the same lines or the same underlying mechanism as another fix — land
them together, not independently, to avoid redoing work:

- **#3 (auto-stop hang) and #15 (CaptureController testability)** are the same piece of work. #15
  extracts the record/settle state machine into a pure `SwingCore.LiveSwingTrigger` struct; #3's
  fix (a missing-sample ceiling that force-stops when wrist tracking drops out) is a field on that
  same struct (`maxMissingFrames`). Do the extraction once, get both fixes and the new tests from it.
- **#4 (stuck recording corrupts file) and #8/#9 (queue serialization / cross-thread reads)** all
  touch `CaptureController.stop()`/`beginRecording()`/`endRecording()` and the queues they run on —
  design them as one coherent concurrency pass over the file, not three separate patches.
- **#13 (pose caching) and the SideBySideView `Task.detached` cancellation fix** touch the same
  lines in `SideBySideView.computeMatch` — land together.
- **#10 (tap letterboxing) exposes `SkeletonCanvas.aspectFit` as non-private** — no conflict with
  anything else, but note it's a visibility change to a file several other fixes don't touch.
- **#5 (Vision orientation) reads `cameraPosition`**, which #9's fix turns into a queue-confined
  shadow (`currentPosition`) instead of the `@Published` property — write #5 against the *post-#9*
  state, not the current cross-thread read, or it'll need a second pass.

---

## Critical

### 1. CI validation harness mostly skips its checks
**Files:** `SwingCore/Sources/SwingCoreCheck/main.swift`, `SwingCore/validate.sh`,
`.github/workflows/ci.yml`

**Problem:** `SWINGCORE_TEST_CLIP`/`_CSV`/`_POSE_JSON`/`_DTL_CLIP` all default to hardcoded absolute
paths outside the repo (one is the original author's `Downloads`, others point into an unrelated
sibling project). `validate.sh` never sets these env vars, so `[Replay]` and `[MLM2ProCSV]` —
which *could* run against fixtures already committed at `ios/DivotTests/Fixtures/sample_swing.pose.json`
and `sample_shots.csv` — silently print `⊘ skipped` in CI. Neither `validate.sh` nor `main.swift`
ever print/assert a check count — the "176 checks" in CLAUDE.md is hand-typed documentation, not
derived from anything the harness enforces.

**Fix design:**
- In `validate.sh`, after computing `PKG`, add `REPO="$(cd "$PKG/.." && pwd)"` and export defaults
  before `swift run`:
  ```bash
  export SWINGCORE_TEST_POSE_JSON="${SWINGCORE_TEST_POSE_JSON:-$REPO/ios/DivotTests/Fixtures/sample_swing.pose.json}"
  export SWINGCORE_TEST_CSV="${SWINGCORE_TEST_CSV:-$REPO/ios/DivotTests/Fixtures/sample_shots.csv}"
  ```
  Deliberately leave `SWINGCORE_TEST_CLIP`/`_DTL_CLIP` (real video, un-committable per the hard
  privacy rule) unset — those *should* keep skipping in CI. That's by design, not a defect.
- In `main.swift`, delete the personal/foreign-repo path literals entirely (the `?? "/Users/..."`
  fallbacks) — use the env var directly with no fallback, so `validate.sh`'s exports become the
  sole source of truth. Running `swingcore-check` bare still degrades gracefully for the clip-only
  sections.
- Add a `total` counter (incremented in `check()`/`approx()`), change the final print to
  `"ALL PASS, \(total) checks"` / `"\(failures) FAILURE(S) of \(total) checks"`. Update
  `Makefile`/`ci.yml`'s `grep -q "ALL PASS"` to `grep -qE "ALL PASS, [0-9]+ checks"`. Once the real
  achievable-in-CI number is known (run once post-fix), add a floor check in `validate.sh` so a
  future accidental mass-skip fails loudly instead of silently.
- Optional: collect skipped section names into a list, print once at the end, so CI logs show the
  skip list in one place.

**Validation:** run `make validate` on a clean clone with no env vars set — confirm `[Replay]` and
`[MLM2ProCSV]` now show real `✓`/`✗` instead of `⊘ skipped`, and the final line reads
`ALL PASS, N checks` with `N` clearly larger. The `[Replay]` section's existing golden numbers
(impact ≈1.87s, fault codes, comparison overall >0) must still pass against the already-committed
fixture — if they don't, that's a real regression, not an artifact of this fix. Scoped to
`SwingCore/`; no need to re-run `make test` for this fix alone. Update CLAUDE.md's `make validate`
line to the new real `N`.

---

### 2. Crash on very short/corrupt clips
**File:** `SwingCore/Sources/SwingCore/Analysis.swift:49` (`argmax`), `Pipeline.swift:27-29`
(`SwingAnalyzer.analyze(video:)`)

**Problem:** `EventDetector.detect`'s `iHi = max(2, min(n, Int(0.92*Double(n))))` evaluates to `2`
even when `n` (frame count) is 0 or 1, so `argmax`/`argmin` index up to `hi-1` against a 0- or
1-length array → fatal out-of-range trap. `analyze(_ pose:)` has no frame-count guard, unlike
`analyzeSession` which already checks `sub.frames.count >= 5`. `PoseEstimator.pose` can
legitimately return a 1-frame or 0-frame sequence for a very short or partially unreadable clip.

**Fix design:** add the identical guard `analyzeSession` already uses, at the one entry point
missing it:
```swift
public static func analyze(_ pose: PoseSequence, club: ClubSpec, angle: Angle, hand: Hand = .right, index: Int = 1) throws -> SwingAnalysis {
    guard pose.frames.count >= 5 else { throw SwingError.noSwingDetected }
    ...
}
```
Reuses the existing `SwingError.noSwingDetected` case rather than inventing a new one.
`Pipeline.swift:28`'s `analyze(try provider.pose(...), ...)` needs `try` added (free, since the
enclosing function is already `throws`). `analyzeSession`'s own `>= 5` filter means it never
actually hits the new guard, but it still needs `try` for the compiler. **Coordination flag:**
grep `ios/` for any direct caller of `SwingAnalyzer.analyze(_ pose:)` (not the `video:` overload) —
any such call site needs `try` added.

**New tests:** add a `[Pipeline degenerate]` bracket (no clip needed):
```swift
print("[Pipeline degenerate]")
let empty0 = PoseSequence(fps: 30, width: 1080, height: 1920, frames: [])
do { _ = try SwingAnalyzer.analyze(empty0, club: pwSpec, angle: .faceOn); check(false, "0-frame pose should throw") }
catch SwingError.noSwingDetected { check(true, "0-frame pose throws noSwingDetected") }
catch { check(false, "0-frame pose threw wrong error: \(error)") }

let oneFrame = PoseSequence(fps: 30, width: 1080, height: 1920, frames: [PoseFrame(t: 0, joints: [:])])
do { _ = try SwingAnalyzer.analyze(oneFrame, club: pwSpec, angle: .faceOn); check(false, "1-frame pose should throw") }
catch SwingError.noSwingDetected { check(true, "1-frame pose throws noSwingDetected") }
catch { check(false, "1-frame pose threw wrong error: \(error)") }
```

**Validation:** before the fix, hand-verify the crash reproduces by feeding an empty `PoseSequence`
through `analyze` in a scratch harness run. After, the two new checks pass cleanly. `make validate`
must still print `ALL PASS`; the real-fixture `[Pipeline]` section is unaffected (`frames.count >= 5`
holds there). Since `analyze(_ pose:)` becoming `throws` is a signature change, run
`rg "SwingAnalyzer.analyze\(" ios/`, add `try`/`try?` at any direct call sites, then
`make generate && make test` — T2 count must stay unchanged.

---

### 3. Live auto-stop can hang forever
**File:** `ios/Divot/Store/CaptureController.swift:135-146` (`detectMotion`)

**Problem:** `detectMotion` does `guard let y = leadWristY else { return }` — when lead-wrist Vision
confidence drops below 0.15 (most likely during/after the downswing, exactly when this feature
exists to capture), the function returns before touching `settleCounter`, so a running recording
never accumulates settle frames and never stops. No manual stop control exists in `CaptureView`.

**Fix design:** this is the same work as **#15** below — extract the state machine into
`SwingCore.LiveSwingTrigger` (a pure, streaming struct mirroring `MotionTrigger.swingWindow`'s
batch logic but per-frame). Give it a `maxMissingFrames` field: a sustained run of nil samples
while recording forces a `.stop` action, independent of wrist-tracking confidence ever recovering.
```swift
public var maxMissingFrames = 45   // safety valve: force-stop if tracking drops out mid-swing
...
public mutating func step(y: Double?, framingOK: Bool) -> Action {
    guard let y else {
        missingSampleRun += 1
        if isRecording, missingSampleRun > maxMissingFrames {
            isRecording = false; settleCounter = 0; missingSampleRun = 0
            return .stop
        }
        return .none
    }
    missingSampleRun = 0
    ... // existing span/settle logic
}
```
`CaptureController` holds `private var trigger = LiveSwingTrigger()`; `detectMotion` collapses to
feeding `trigger.step(y:framingOK:)` and switching on the returned `Action` to call
`beginRecording()`/`endRecording()`. A manual stop button is a separate product decision (the app
is explicitly auto-only by design) — out of scope here; this fix guarantees termination without
requiring one.

**New tests:** see the full `LiveSwingTriggerTests.swift` design under **#15** — the specific
regression case for this finding is `testWristTrackingLostDuringSwingForcesStop()`.

**Validation:** (a) *bug fixed:* on a real iPhone (T3), start a swing, then deliberately obscure the
lead wrist immediately after the trigger fires and confirm recording stops within the configured
ceiling instead of running indefinitely. To validate the *test* isn't vacuous: temporarily set
`maxMissingFrames` to `10_000`, confirm `testWristTrackingLostDuringSwingForcesStop` fails/times
out, then revert and confirm it passes. (b) *no regression:* on-device, run a normal clean swing
and confirm it still stops at the natural settle point, well before the ceiling. `make test` (T2)
for the new unit tests plus the two existing pure-helper tests (`testDtlModeSelectsGuide`,
`testCameraSwitchTogglesPosition`) unchanged.

---

### 4. Backing out of a stuck/in-progress recording corrupts or orphans the video file
**File:** `ios/Divot/Store/CaptureController.swift:110` (`stop()`) vs. `148-158` (`endRecording()`)

**Problem:** `stop()` only calls `session.stopRunning()` — never checks/stops `movieOutput` first,
unlike `endRecording()` which does it correctly. `CaptureView.swift:79`'s `.onDisappear { cap.stop() }`
calls this whenever the view goes away, including mid-recording (most likely via the #3 hang, where
backing out is the user's only recourse).

**Fix design:** reuse the existing `AVCaptureFileOutputRecordingDelegate` callback
(`fileOutput(_:didFinishRecordingTo:...)`) as the completion point:
```swift
private var pendingTeardown = false

func stop() {
    sessionQueue.async {
        if self.movieOutput.isRecording {
            self.pendingTeardown = true
            self.movieOutput.stopRecording()   // finalization completes async, via the delegate callback
        } else if self.session.isRunning {
            self.session.stopRunning()
        }
    }
}

func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                from connections: [AVCaptureConnection], error: Error?) {
    DispatchQueue.main.async { self.isRecording = false }
    if pendingTeardown {
        pendingTeardown = false
        try? FileManager.default.removeItem(at: outputFileURL)   // user cancelled mid-swing; don't keep a half-finalized clip
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
        return
    }
    Task { await self.autoTrim(outputFileURL) }
}
```
This makes `stop()` finalize the movie file properly before the session goes down, and discards the
abandoned clip cleanly instead of leaving a truncated `cap-*.mov` in `tmp/` (ties into #16's cleanup
theme).

**Validation:** T3-only (no camera on Simulator). (a) *bug fixed:* on-device, trigger a recording,
then immediately tap Cancel (X) mid-swing before it naturally settles; confirm no orphaned
`cap-*.mov` remains afterward (check `FileManager.default.temporaryDirectory`), and the app doesn't
crash/hang on dismiss. (b) *no regression:* run a normal full swing to natural completion and
confirm `autoTrim`/`lastClipURL`/`onCaptured` still fire exactly as before — this path is untouched.

---

### 5. Live pose tracking hardcodes `.up` orientation
**File:** `ios/Divot/Store/CaptureController.swift:118-120`

**Problem:** `VNImageRequestHandler(cmSampleBuffer:orientation: .up, ...)` is hardcoded for every
live frame; nothing anywhere sets `videoOrientation`/`videoRotationAngle` on the capture connection.
Held portrait (the only realistic way to record a golf swing), Vision analyzes a frame rotated 90°
from what it assumes — plausibly the root cause of the framing/trigger misfires from the earlier
debugging session.

**Fix design:** derive the correct `CGImagePropertyOrientation` from the connection's rotation angle
and camera position, as a pure, testable static helper matching the existing `framing`/
`nextPosition` pattern:
```swift
static func visionOrientation(rotationAngle: CGFloat, position: AVCaptureDevice.Position) -> CGImagePropertyOrientation {
    let mirrored = position == .front
    switch rotationAngle {
    case 90:  return mirrored ? .leftMirrored  : .right
    case 270: return mirrored ? .rightMirrored : .left
    case 0:   return mirrored ? .upMirrored    : .up
    default:  return mirrored ? .downMirrored  : .down   // 180
    }
}
```
In `captureOutput`:
```swift
let orientation = Self.visionOrientation(rotationAngle: connection.videoRotationAngle, position: currentPosition)
let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: orientation, options: [:])
```
Uses `connection.videoRotationAngle` (modern iOS 17+ API, not the deprecated `videoOrientation`).
Read `currentPosition` — the **post-#9** queue-confined shadow value — not the raw `@Published
cameraPosition`, since this runs on `capture.frames`.

**New tests:** pure math, add to `AppValidationTests.swift` next to the other `CaptureController`
helper tests (no `#if targetEnvironment(simulator)` needed):
```swift
func testVisionOrientationAccountsForRotationAndMirroring() {
    XCTAssertEqual(CaptureController.visionOrientation(rotationAngle: 90, position: .back), .right)
    XCTAssertEqual(CaptureController.visionOrientation(rotationAngle: 90, position: .front), .leftMirrored)
    XCTAssertEqual(CaptureController.visionOrientation(rotationAngle: 0, position: .back), .up)
}
```

**Validation:** (a) *bug fixed:* this is the highest-value manual T3 pass in the whole batch given
its tie to the earlier diagnostic session — on-device, hold the phone in normal portrait
orientation, confirm `framingOK` turns green promptly and stays stable, and that the wrist-Y span
`detectMotion` reads behaves sanely (temporarily log `joints[.leftWrist]` if needed to eyeball it,
as was done in the earlier session). Compare against the pre-fix flickering/misfiring behavior.
(b) *no regression:* `make test` (new pure test + all existing pass); `make device-test` (T3, full
on-device swing capture flow end to end).

---

### 6. Silent garbage events when a joint is never detected across a clip
**Files:** `SwingCore/Sources/SwingCore/PoseEstimator.swift:57-68` (dead `SwingError.lowPoseConfidence`),
`Analysis.swift:49-50` (`argmax`/`argmin`), `Models.swift` (unused `framesDetected`)

**Problem:** if the tracked lead-wrist joint is undetected across an *entire* clip,
`JointSeries.interp` has no anchor to fill from — that joint's series stays all-NaN. Since
`NaN > x`/`NaN < x` are always `false` in Swift, `argmax`/`argmin` never advance past their initial
index — `address`/`top`/`impact` deterministically collapse to fixed, meaningless indices. No
crash, no error: the full pipeline runs on this garbage and presents it as a legitimate analysis.
The error case built for exactly this (`SwingError.lowPoseConfidence`) is never thrown anywhere.

**Fix design:** add a second, independent guard in `SwingAnalyzer.analyze(_ pose:)`, right after
the frame-count guard from #2 — a *coverage* check across the whole clip, distinct from
`PoseEstimator`'s existing per-point `minConfidence: 0.15` gate (which only decides whether a joint
counts as detected in a single frame):
```swift
guard pose.frames.count >= 5 else { throw SwingError.noSwingDetected }
let lead = hand.leadWrist   // see consolidation note below
let leadDetected = pose.frames.filter { $0.joints[lead] != nil }.count
guard Double(leadDetected) / Double(pose.frames.count) >= 0.5 else { throw SwingError.lowPoseConfidence }
```
The `hand == .left ? .rightWrist : .leftWrist` mapping is currently copy-pasted in
`EventDetector.detect` and `Segmenter.swings` — as a small drive-by consolidation, fold it into
`extension Hand { var leadWrist: Joint { self == .left ? .rightWrist : .leftWrist } }` in
`Models.swift` and use it at all three sites.

**New tests:** add to the same `[Pipeline degenerate]` bracket from #2:
```swift
func noWristPose() -> PoseSequence {
    var frames: [PoseFrame] = []
    for i in 0..<20 {
        frames.append(PoseFrame(t: Double(i)/30, joints: [
            .leftShoulder: JointPoint(x: 0.42, y: 0.75, c: 1), .rightShoulder: JointPoint(x: 0.58, y: 0.75, c: 1),
            .leftHip: JointPoint(x: 0.45, y: 0.55, c: 1), .rightHip: JointPoint(x: 0.55, y: 0.55, c: 1),
        ]))  // leftWrist deliberately absent in every frame
    }
    return PoseSequence(fps: 30, width: 1000, height: 1000, frames: frames)
}
do { _ = try SwingAnalyzer.analyze(noWristPose(), club: pwSpec, angle: .faceOn); check(false, "fully-undetected lead wrist should throw") }
catch SwingError.lowPoseConfidence { check(true, "fully-undetected lead wrist throws lowPoseConfidence") }
catch { check(false, "wrong error for undetected wrist: \(error)") }
```

**Validation:** (a) before the fix, hand-verify `noWristPose()` fed through the old `analyze`
returns a `SwingAnalysis` with `address.frame == top.frame == impact.frame == 0` instead of
erroring; after, it throws `lowPoseConfidence`. (b) `make validate` — confirm real-fixture
`[Events]`/`[Metrics]`/`[Pipeline]` (>90% lead-wrist detection) and `[Replay]` still pass unchanged;
the 0.5 floor is well below that fixture's real coverage.

---

## High

### 7. Left-handed golfer plane-sign flip
**File:** `SwingCore/Sources/SwingCore/PlaneEngine.swift:32-37`

**Problem:** the swing-plane normal uses a fixed 90° rotation (`nx = -dy/len, ny = dx/len`)
independent of `hand`, while joint *selection* elsewhere is already hand-aware. Mirroring the swing
geometry (a lefty's swing relative to a righty's, same camera side) flips `dev`'s sign, so a genuine
over-the-top move gets classified as shallow and vice versa.

**Fix design:** `PlaneEngine.analyze` already receives `hand` and threads it into
`SwingLines.shaftPlane`/`handPath` — apply it to this one line too:
```swift
let nxRaw = -dy / len, nyRaw = dx / len
let mirror: Double = hand == .left ? -1 : 1
let nx = nxRaw * mirror, ny = nyRaw * mirror
```
This is the direct algebraic undo: the plane's endpoints are already mirror-images between
right/left swings (via hand-aware joint selection), so a fixed rotation of a mirrored line produces
a mirrored normal — multiplying by `-1` cancels that.

**New tests:** extend `[ClubPath]` with a left-handed mirror of the existing `cpPose`/`cpEvents`/
`cpBall` fixtures (mirror every x about 0.5, use `.rightWrist` per the lead/trail convention):
```swift
let overL = PlaneEngine.analyze(cpPoseL(0.2), events: cpEvents, hand: .left, ball: cpBallL)
check(overL.overTheTop, "left-handed mirror of over-the-top synthetic ⇒ true (maxAbove \(overL.maxAbovePlane))")
let shallowL = PlaneEngine.analyze(cpPoseL(0.6), events: cpEvents, hand: .left, ball: cpBallL)
check(!shallowL.overTheTop, "left-handed mirror of shallow synthetic ⇒ false (maxAbove \(shallowL.maxAbovePlane))")
```
(Full fixture construction — `cpFrameL`/`cpPoseL`/`cpBallL` — mirrors the existing right-handed
helpers with x-coordinates flipped about 0.5.)

**Validation:** (a) run `make validate` before the fix: `overL.overTheTop` is `false` (sign-flipped)
— the new check fails, proving the bug reproduces headlessly. After, both new checks pass.
(b) the pre-existing `.right`-hand checks must produce byte-identical `maxAbovePlane` values — diff
the log before/after. Also re-run the `[Replay]`-driven plane check (`hand: .right`), unaffected.

---

### 8. No serialization between camera reconfiguration and recording start/stop
**File:** `ios/Divot/Store/CaptureController.swift:32-34, 93-104, 148-158`

**Problem:** `switchCamera()`/`configure()` run on `sessionQueue`; `beginRecording()`/
`endRecording()` currently run directly on the `capture.frames` delegate queue, mutating the same
`session`/`movieOutput` with no shared serialization — a known source of `AVCaptureSession`
crashes/corrupted output when reconfiguration races an active recording.

**Fix design:** land together with #9's state-mirroring split. Keep `detectMotion`'s decision logic
(cheap, no AVFoundation calls) running synchronously on `capture.frames`, but dispatch the actual
`movieOutput.startRecording`/`stopRecording` calls onto `sessionQueue`:
```swift
private func beginRecording() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cap-\(UUID().uuidString).mov")
    DispatchQueue.main.async { self.isRecording = true }
    sessionQueue.async {
        guard !self.movieOutput.isRecording else { return }
        self.movieOutput.startRecording(to: url, recordingDelegate: self)
    }
}
private func endRecording() {
    settleCounter = 0
    sessionQueue.async { if self.movieOutput.isRecording { self.movieOutput.stopRecording() } }
}
```
Now every mutation of `session`/`movieOutput`/`currentInput` is serialized on `sessionQueue` —
matching the file's existing intent (the queue is already named for this purpose) rather than
introducing a new lock.

**Validation:** T3-only (queue-serialization property, not a pure value transform). On-device,
rapidly tap the switch-camera button several times in a row while a swing is actively
recording/settling, and confirm no crash and no corrupted output — previously a race window.
Normal single camera-switch before recording starts should show no added latency
(`sessionQueue.async` dispatch is sub-millisecond).

---

### 9. `@Published` capture state read cross-thread with no synchronization
**File:** `ios/Divot/Store/CaptureController.swift:129-133, 140-145, 74/99-100`

**Problem:** `dtlMode` (written on main via `Picker`, read on `capture.frames`), `cameraPosition`
(written via `DispatchQueue.main.async`, read on `sessionQueue` by the next `switchCamera()` call),
and `isRecording` (written async, read directly on the frame queue, so it can lag several frames
behind reality) are all read off the queue that owns their true state, with no synchronization —
a genuine data race under Swift's memory model.

**Fix design:** `CaptureController` is not `@MainActor` — correctly, since its delegate callbacks
arrive synchronously on background queues and can't be actor-isolated without breaking the delegate
protocol conformance (unlike `AnalysisStore`, which *is* `@MainActor` because none of its work is a
synchronous delegate callback). The pattern: **for each piece of state, pick one queue as the
source of truth; the other side's copy is a write-only mirror, never read back into logic.**

- **`cameraPosition`** — logic-owned. `sessionQueue` becomes the source of truth via a new private
  `currentPosition`; `@Published var cameraPosition` becomes a write-only-from-sessionQueue mirror
  for the UI. `addCameraInput`'s existing `DispatchQueue.main.async { self.highFps = ... }` is the
  precedent for this exact one-way pattern — extend it to `cameraPosition`.
- **`dtlMode`** — UI-owned (`Picker` sets it). Main stays the source of truth, mirrored to a
  `capture.frames`-confined shadow via `didSet`:
  ```swift
  @Published var dtlMode = false { didSet { frameQueue.async { self.dtlModeSnapshot = self.dtlMode } } }
  private var dtlModeSnapshot = false   // capture.frames-confined mirror
  ```
  Needs `frameQueue` hoisted to a stored `private let frameQueue = DispatchQueue(label: "capture.frames")`
  (currently created inline/anonymous at `configure()`), passed into `setSampleBufferDelegate`.
  `captureOutput` reads `dtlModeSnapshot` instead of `dtlMode`.
- **`isRecording`** — becomes moot for the logic path once #3/#8's `recordingSnapshot`/`trigger`
  (a plain, `capture.frames`-confined value, never `@Published`) replaces the cross-thread read.
  `@Published var isRecording` remains purely a UI mirror.

**Validation:** no direct crash reproduction exists (data races don't reliably crash) — validate
via Thread Sanitizer: run the app with TSan enabled (Xcode scheme → Diagnostics → Thread Sanitizer)
through a full capture session (switch camera, toggle DTL mode, record a swing) and confirm no race
reported on `cameraPosition`/`dtlMode`/`isRecording` — before the fix, TSan should flag these.
`make test` (T2) for pure-helper tests; `make device-test` (T3) for a full manual session with
camera switching and DTL toggling mid-recording.

---

### 9b. Vision joint confidence captured but never consulted downstream
**Files:** `SwingCore/Sources/SwingCore/PoseEstimator.swift:46-47` (`JointPoint.c` written),
`Analysis.swift:22` (only `.x`/`.y` read)

**Problem:** once a joint clears the flat `minConfidence: 0.15` cutoff, a detection at confidence
0.16 is weighted identically to one at 0.99 in every downstream smoothing/interpolation/metric — a
noisy, barely-passing sample silently degrades event detection and every biomechanical metric.

**Fix design:** additive against the existing tolerance-based golden checks, not a rewrite:
- `JointSeries.init` also collects `cs: [Joint: [Double]]` from `p.c` (default `1.0` for
  gap-filled/interpolated samples, since `interp` already handles gaps and they shouldn't be
  double-penalized).
- `smooth` gets an optional-weights overload:
  `static func smooth(_ a: [Double], _ weights: [Double]? = nil, _ win: Int = 3) -> [Double]`,
  using `s += a[k] * (weights?[k] ?? 1); c += (weights?[k] ?? 1)`. Existing unweighted call sites
  (`MotionTrigger.swingWindow`, `EventDetector`'s speed smoothing, `SequenceEngine`'s angular-speed
  smoothing) keep calling `smooth(a)` unchanged.
- `JointSeries.init` calls `smooth(x, cs[j])`/`smooth(y, cs[j])` instead of `smooth(x)`/`smooth(y)`
  — the one behavior change, confined to per-joint position smoothing.

**New tests:**
```swift
print("[JointSeries weighting]")
let vals =    [1.0, 1.0, 1.0, 9.0, 1.0, 1.0, 1.0]
let weights = [1.0, 1.0, 1.0, 0.05, 1.0, 1.0, 1.0]
let unweighted = JointSeries.smooth(vals, nil, 1)
let weighted = JointSeries.smooth(vals, weights, 1)
check(weighted[3] < unweighted[3], "low-confidence outlier pulled toward neighbors when weighted")
```
**Caveat to verify before implementing:** confirm `JointSeries`/`smooth` visibility is reachable
from `SwingCoreCheck` (a separate executable target importing `SwingCore` as a regular, not
`@testable`, dependency) — if not, this micro-check isn't directly portable; note it and fall back
to validation (b) only rather than silently dropping the check.

**Validation:** (a) the `[JointSeries weighting]` check, if visibility allows. (b) `make validate`
must still print `ALL PASS`; every existing `approx()` in `[Metrics]`, `[Events]`, `[SwingLines]`,
`[AngleDetector]`, `[P2 clip]`, `[Replay]` must still pass against the real/replay fixture. If any
tolerance needs loosening, do it explicitly and document the before/after value.

---

### 10. Tap-to-set-ball-position doesn't account for the renderer's letterboxing
**Files:** `ios/Divot/Views/DTLPlaneView.swift:47-58`, `ios/Divot/Rendering/SkeletonCanvas.swift:29-51,115-119`

**Problem:** the tap gesture normalizes against the raw `GeometryReader` size, but `SkeletonCanvas`
internally computes an `aspectFit` sub-rect and centers content inside the container. Whenever the
container's aspect ratio doesn't exactly match the clip's (normal here, given the surrounding
banner/label/controls), a tap lands offset from the anchor it produces.

**Fix design:** `SkeletonCanvas.aspectFit(image:in:)` is currently `private` — drop `private` and
add a sibling returning the centered origin too:
```swift
static func aspectFit(image: CGSize, in container: CGSize) -> CGSize { … }   // was private
static func aspectFitRect(image: CGSize, in container: CGSize) -> CGRect {
    let size = aspectFit(image: image, in: container)
    let origin = CGPoint(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2)
    return CGRect(origin: origin, size: size)
}
```
In `DTLPlaneView`'s gesture, map through the same rect instead of the raw container:
```swift
.gesture(SpatialTapGesture().onEnded { e in
    guard snap.phase == .address, geo.size.width > 0, geo.size.height > 0 else { return }
    let rect = SkeletonCanvas.aspectFitRect(image: snap.image.size, in: geo.size)
    guard rect.width > 0, rect.height > 0 else { return }
    let lx = e.location.x - rect.minX, ly = e.location.y - rect.minY
    guard (0...rect.width).contains(lx), (0...rect.height).contains(ly) else { return } // tapped in letterbox padding
    let n = CGPoint(x: min(max(lx / rect.width, 0), 1), y: min(max(ly / rect.height, 0), 1))
    Task { await setBall(n) }
})
```
Reuses `SkeletonCanvas`'s own math so the two can't drift apart again.

**New tests:** expose the tap→normalized-point mapping as a small pure static func (matching the
"pure scrubber math" precedent already noted in `SwingPlayerView.swift:8`'s `ScrubberMath`); add
XCTest cases: a tap at the container's exact center maps to image-space `(0.5, 0.5)` for both
letterboxed-left/right and letterboxed-top/bottom containers; a tap in the letterbox padding is
ignored; a tap at an image edge clamps to `0`/`1`.

**Validation:** `make generate && make test`. Manual Simulator pass (Replay provider is already the
default there): seed sample data, open a session's "Plane & path", tap directly on the ball at
several screen positions, confirm the anchor lands exactly under the tap. Repeat across different
Simulator device sizes to stress the letterbox math differently.

---

### 11. Signing secrets in untracked worktrees with no explicit gitignore protection
**Files:** `.claude/worktrees/<agent-*>/ios/Config/Signing.local.xcconfig`, `.../embedded.mobileprovision`

**Problem:** real `DEVELOPMENT_TEAM`, device UDIDs, and a provisioning profile sit in 17 stray
worktree directories, protected today only incidentally (each is a git worktree/gitlink) — the root
`.gitignore` never lists `.claude/worktrees/` itself.

**Fix design:** not an application-code fix. Add one line to `.gitignore`'s existing "Claude Code"
section:
```
# Claude Code
.claude/settings.local.json
.claude/worktrees/
claude_docs/
```
Then clean up the 17 stray worktrees (`git worktree list`, `git worktree remove <path>` for each no
longer needed) as a one-time hygiene pass, not a code change.

**Validation:** (a) after adding the line, `git status` should no longer show `.claude/worktrees/`
as untracked content; `git check-ignore -v .claude/worktrees/<any-dir>/ios/Config/Signing.local.xcconfig`
should report the new rule as the match. (b) confirm `git worktree list` still shows worktrees
functioning normally (gitignoring the parent path doesn't affect git's own worktree bookkeeping,
which lives in `.git/worktrees/`) — create a throwaway test worktree afterward and confirm it still
works exactly as before.

---

### 12. Swing video/analysis data not excluded from iCloud backup
**Files:** `ios/Divot/Models/SavedSession.swift:58-67` (`AppPaths.videosDir`),
`ios/Divot/Store/AnalysisStore.swift:19`

**Problem:** nothing sets `isExcludedFromBackup` anywhere in `ios/`; files under `Documents/` are
backed up to iCloud by default, contradicting the "video never leaves the phone" claim if the user
has device backup enabled.

**Fix design:** set the resource value at the point the directory is created:
```swift
enum AppPaths {
    static var videosDir: URL {
        var d = documents.appendingPathComponent("videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? d.setResourceValues(rv)
        return d
    }
}
```
(Needs `var d`, not `let d` — `setResourceValues` mutates.) Bundle the Low-priority file-protection
fix in the same call: `rv.fileProtectionType = .completeUnlessOpen`, same `setResourceValues` call.

**New tests:**
```swift
func testVideosDirExcludedFromBackup() throws {
    let values = try AppPaths.videosDir.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(values.isExcludedFromBackup, true, "swing video must never be included in iCloud device backup")
}
```
Runs fine on the Simulator (plain `FileManager` behavior, no camera/Vision needed).

**Validation:** (a) the new test fails before the fix, passes after. (b) `make test` — full count
still passes; manually confirm video files still play back correctly in `SwingPlayerView` after the
change (resource-value change doesn't touch file bytes/path, but worth a sanity check).

---

### 13. Pose estimation never cached — every review screen re-runs it from scratch
**Files:** `SwingCore/Sources/SwingCore/PoseProvider.swift`, `ios/Divot/Store/FrameExtractor.swift:58`,
`FrameExtractorMotion.swift:10`, `ios/Divot/Views/SideBySideView.swift:107-108`,
`ios/Divot/Store/CaptureController.swift:168`

**Problem:** `PoseEstimator.pose` (full frame decode + per-frame Vision, serially) is the single
most expensive operation in the app, re-run from scratch with zero caching at capture, at
import/analysis, and again on every visit to Ghost/Motion/Side-by-side.

**Fix design:** `PoseSequence` is already `Codable` (`ReplayPoseProvider.init(contentsOf:)` already
does `JSONDecoder().decode(PoseSequence.self, from:)`, and the repo ships a serialized example as
`sample_swing.pose.json`) — reuse that exact precedent rather than inventing a new cache format.

Add a cache directory next to `videosDir`:
```swift
static var poseCacheDir: URL {
    let d = documents.appendingPathComponent("poseCache", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}
```
Add to `SavedSession`: `var poseCacheURL: URL { AppPaths.poseCacheDir.appendingPathComponent(videoFilename).appendingPathExtension("pose.json") }`.

New file `ios/Divot/Store/PoseCache.swift`, matching the codebase's "enum namespace of static funcs"
convention (`FrameExtractor`, `AppPaths`, `TrendsData` are all this shape):
```swift
enum PoseCache {
    private static func cached(at url: URL) -> PoseSequence? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PoseSequence.self, from: data)
    }
    private static func store(_ seq: PoseSequence, at url: URL) {
        guard let data = try? JSONEncoder().encode(seq) else { return }
        try? data.write(to: url)
    }
    /// Review screens — replay-backed on the Simulator, real Vision on device (matches PoseProviderFactory).
    static func pose(videoURL: URL, cacheURL: URL, fps: Double = 30) async -> PoseSequence? {
        if let hit = cached(at: cacheURL) { return hit }
        guard let seq = try? PoseProviderFactory.make().pose(for: videoURL, fps: fps) else { return nil }
        store(seq, at: cacheURL)
        return seq
    }
    /// Device-gated motion analysis (P2.3/P2.4) — always real Vision, nil on the Simulator by design.
    static func devicePose(videoURL: URL, cacheURL: URL) async -> PoseSequence? {
        if let hit = cached(at: cacheURL) { return hit }
        guard let seq = try? PoseEstimator.pose(video: videoURL), !seq.frames.isEmpty else { return nil }
        store(seq, at: cacheURL)
        return seq
    }
}
```
Two entry points, not one: `FrameExtractorMotion.motion` deliberately bypasses `PoseProviderFactory`
today (real Vision only, nil on Simulator by design for kinematic fidelity) — the cache must
preserve that, not silently let Motion fall back to replay data on the Simulator.

Call-site changes: `FrameExtractor.snapshots`/`FrameExtractorMotion.motion` take a `SavedSession`
instead of a bare `videoURL` so they can read `poseCacheURL`; update `DTLPlaneView.swift:129` and
`GhostCompareView.swift:77` call sites accordingly. `MotionView.swift`'s call site needs the same
update (not in this pass's read scope — flag for whoever lands this). `SideBySideView.computeMatch`
already extracts primitives before its `Task.detached` to avoid capturing non-`Sendable` `@Model`
types — also extract `cacheA`/`cacheB` (plain `URL`, `Sendable`) and call `PoseCache.pose(videoURL:cacheURL:)`
in place of the raw `PoseEstimator.pose` call (land together with the `Task.detached` cancellation
fix below — same lines).

Cache lifetime: the video file never changes in place once written, so no invalidation logic beyond
deleting `poseCacheURL` wherever a `SavedSession` and its video are deleted (likely `HistoryView.swift`
— flag as a required companion edit, not in this pass's scope).

**New tests:** call `PoseCache.pose(videoURL:cacheURL:)` twice with the same `cacheURL`, then point
the *second* call's `videoURL` at a nonexistent path and assert it still returns a sequence equal to
the first — if it had ignored the cache, it would fail to decode a nonexistent video and return
`nil`, proving the cache was actually served.

**Validation:** `make generate && make test`. Manual Simulator pass: seed sample data, open a
session → Ghost → back → Motion → back → Plane & path; confirm all three render identical
skeletons/overlays to before (functional parity), and a cache file now exists under
`Documents/poseCache/` after the first visit. Speed win itself is best confirmed with Instruments
Time Profiler comparing first-visit vs. second-visit wall time, not a hard assertion.

---

### 14. Accessibility: form fields and video-playback controls unusable with VoiceOver
**Files:** `ios/Divot/Views/ShotDataForm.swift:39-42`, `ios/Divot/Views/SwingPlayerView.swift:102-142`

**Problem:** `ShotDataForm`'s `field()` passes `""` as the `TextField`'s label (doubling as its
accessibility label) — every field announces as "text field, blank." `SwingPlayerView`'s
frame-step/play/pause buttons have no `.accessibilityLabel`, and the hand-built scrubber (a bare
`Capsule`/`DragGesture`) has no accessibility element/value/adjustable action — a VoiceOver user
cannot scrub playback at all.

**Fix design:**
```swift
// ShotDataForm.swift — keep the visual placeholder, label it for VoiceOver
private func field(_ label: String, _ text: Binding<String>) -> some View {
    HStack { Text(label); Spacer()
        TextField("", text: text)
            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
            .accessibilityLabel(label)
    }
}
```
```swift
// SwingPlayerView.swift — transport buttons
Button { model.step(-1) } label: { Image(systemName: "backward.frame.fill") }
    .accessibilityLabel("Previous frame")
Button { model.playPause() } label: { Image(systemName: model.rate == 0 ? "play.fill" : "pause.fill") }
    .accessibilityLabel(model.rate == 0 ? "Play" : "Pause")
Button { model.step(1) } label: { Image(systemName: "forward.frame.fill") }
    .accessibilityLabel("Next frame")
// rate buttons additionally get .accessibilityAddTraits(model.rate == r ? .isSelected : [])
```
```swift
// SwingPlayerView.swift — scrubber: VoiceOver swipe-up/down stands in for the drag gesture
.accessibilityElement(children: .ignore)
.accessibilityLabel("Playback position")
.accessibilityValue(Text(String(format: "%.1f seconds", model.current)))
.accessibilityAdjustableAction { direction in
    let step = model.duration > 0 ? model.duration * 0.02 : 0.1
    switch direction {
    case .increment: model.seek(to: min(model.duration, model.current + step))
    case .decrement: model.seek(to: max(0, model.current - step))
    @unknown default: break
    }
}
```

**New tests:** `AccessibilityAuditTests.swift` currently only visits the tab bar + My Bag — it never
navigates into a saved session's Results screen, so it structurally cannot catch either bug today.
Extend the same test (using `waitForExistence`, not more `sleep()`, per the sleep→readiness fix
below) to: tap into History → a seeded session → Results, run `audit()`; tap "Play / slow-mo" → run
`audit()`; back out, tap "Add" shot data → run `audit()` against the `ShotDataForm` sheet. Requires
`-seedSampleData` to seed at least one `SavedSession` with swings reachable from History — confirm
this is already true before relying on it. Additionally assert the selected-rate trait round-trips:
`app.buttons["1× speed"].tap(); XCTAssertTrue(app.buttons["1× speed"].isSelected)`.

**Validation:** before applying the code fix, temporarily run the *extended* audit against the
current (unfixed) code and confirm it fails on the new screens — proves the new navigation coverage
actually reaches the broken elements. Apply the fixes, confirm `make test` passes with the audit
green on all now-visited screens. Test count unchanged (still 2 UI tests), coverage increased.

---

### 15. `CaptureController`'s live record/settle state machine has zero test coverage
**File:** `ios/Divot/Store/CaptureController.swift:135-158` (`detectMotion`, `beginRecording`,
`endRecording`)

**Problem:** all three are `private`, mutating instance state tangled with AVFoundation calls — none
of the actual start/settle/stop decision logic is reachable from XCTest as written.

**Fix design — extract into a pure, streaming state struct.** `MotionTrigger.swingWindow` in
SwingCore is the existing "pure enough to validate headlessly" precedent, but it's a **batch**
algorithm over a complete `[Double]`; this logic is the same *shape* (rolling window + threshold +
hysteresis) but **streaming** (one sample per camera frame). Add a new pure, `Sendable` struct
alongside `swingWindow` in the same file (SwingCore is explicitly "no app imports," and this logic
has zero AVFoundation/Vision dependency once decoupled):
```swift
/// Streaming counterpart to `swingWindow`: consumes one lead-wrist-Y sample per camera frame and
/// decides start/stop, instead of `swingWindow`'s one-shot batch analysis over an already-recorded
/// series. Pure so the live capture controller's decision logic is testable without AVFoundation/Vision.
public struct LiveSwingTrigger: Sendable {
    public private(set) var recentY: [Double] = []
    public private(set) var isRecording = false
    public private(set) var settleCounter = 0
    private var missingSampleRun = 0

    public var windowSize = 12
    public var minSamples = 6
    public var startSpan = 0.20
    public var settleSpan = 0.03
    public var settleFrames = 15
    public var maxMissingFrames = 45   // see finding #3

    public enum Action { case none, start, stop }
    public init() {}

    public mutating func step(y: Double?, framingOK: Bool) -> Action {
        guard let y else {
            missingSampleRun += 1
            if isRecording, missingSampleRun > maxMissingFrames {
                isRecording = false; settleCounter = 0; missingSampleRun = 0
                return .stop
            }
            return .none
        }
        missingSampleRun = 0
        recentY.append(y); if recentY.count > windowSize { recentY.removeFirst() }
        guard recentY.count >= minSamples else { return .none }
        let span = (recentY.max() ?? 0) - (recentY.min() ?? 0)
        if !isRecording, framingOK, span > startSpan { isRecording = true; return .start }
        if isRecording {
            settleCounter = span < settleSpan ? settleCounter + 1 : 0
            if settleCounter > settleFrames { isRecording = false; settleCounter = 0; return .stop }
        }
        return .none
    }
}
```
`CaptureController` holds `private var trigger = LiveSwingTrigger()`; `detectMotion` collapses to
feeding `trigger.step(y:framingOK:)` and switching on the returned `Action`.

**New tests:** new file `ios/DivotTests/LiveSwingTriggerTests.swift` (mirrors the existing
per-feature file split, e.g. `Wave3Tests.swift`), `import SwingCore`, no `@testable import Divot`
needed since the type lives in SwingCore:
```swift
final class LiveSwingTriggerTests: XCTestCase {
    func testCleanSingleSwing() {
        var t = LiveSwingTrigger()
        for y in [0.5,0.5,0.5,0.5,0.5,0.5] { _ = t.step(y: y, framingOK: true) }
        var actions: [LiveSwingTrigger.Action] = []
        for y in [0.5,0.55,0.65,0.75,0.55,0.45] { actions.append(t.step(y: y, framingOK: true)) }
        XCTAssertEqual(actions.filter { $0 == .start }.count, 1)
        for _ in 0..<20 { actions.append(t.step(y: 0.5, framingOK: true)) }
        XCTAssertEqual(actions.filter { $0 == .stop }.count, 1)
    }
    func testHighVarianceNeverSettles() {
        var t = LiveSwingTrigger()
        for y in [0.5,0.5,0.5,0.5,0.5,0.5,0.55,0.65,0.75,0.55,0.45] { _ = t.step(y: y, framingOK: true) }
        XCTAssertTrue(t.isRecording)
        for i in 0..<100 { _ = t.step(y: 0.5 + (i % 2 == 0 ? 0.05 : -0.05), framingOK: true) }
        XCTAssertTrue(t.isRecording, "never settles ⇒ never stops without the missing-sample valve")
    }
    func testBackToBackSwings() { /* two burst-and-settle cycles ⇒ 2 starts, 2 stops */ }
    /// Regression test for finding #3.
    func testWristTrackingLostDuringSwingForcesStop() {
        var t = LiveSwingTrigger()
        for y in [0.5,0.5,0.5,0.5,0.5,0.5,0.55,0.65,0.75,0.55,0.45] { _ = t.step(y: y, framingOK: true) }
        XCTAssertTrue(t.isRecording)
        var stopped = false
        for _ in 0...t.maxMissingFrames { if t.step(y: nil, framingOK: true) == .stop { stopped = true } }
        XCTAssertTrue(stopped, "sustained nil samples force a stop instead of hanging")
    }
    func testFramingLossDoesNotStartARecording() { /* burst while framingOK: false ⇒ never starts */ }
}
```

**Validation:** (a) *confirm non-vacuous:* temporarily change `settleFrames` from `15` to `150` and
confirm `testCleanSingleSwing`'s stop-assertion fails; revert, confirm it passes. Same for
`maxMissingFrames` (set to `10_000`, confirm `testWristTrackingLostDuringSwingForcesStop`
fails/times out, revert). (b) `make generate && make test` — adds 5 unit tests; update CLAUDE.md's
documented "56 unit (+4 device-skipped) + 2 UI" to 61 (none of the 5 need Simulator/device
gating — pure logic). (c) once `CaptureController` delegates to `LiveSwingTrigger` (the #3/#4/#8/#9
wiring), re-run `make test` and confirm `testDtlModeSelectsGuide`/`testCameraSwitchTogglesPosition`
still pass unchanged.

---

### 16. Orphaned files: failed analysis and successful auto-trim both leak files
**Files:** `ios/Divot/Store/AnalysisStore.swift:14-33` (`analyze`), `CaptureController.swift:166-183`
(`autoTrim`)

**Problem:** `analyze()` copies the video into permanent storage *before* analysis runs; if it
throws, the copy is never cleaned up. `autoTrim` never deletes the original full-length recording
after producing a trimmed clip.

**Fix design:** for `AnalysisStore`, clean up in both catch branches (hoist `dest`'s computation
above the `do` block so both arms can reach it):
```swift
} catch let e as SwingError {
    try? FileManager.default.removeItem(at: dest)
    error = e.description; return nil
} catch {
    try? FileManager.default.removeItem(at: dest)
    self.error = error.localizedDescription; return nil
}
```
For `autoTrim`, delete `url` only in the success path (it's also the fallback *return* value on
failure — must not delete it there):
```swift
do {
    try await export.export(to: out, as: .mov)
    final = out
    try? FileManager.default.removeItem(at: url)   // trim succeeded; drop the untrimmed original
}
catch { final = url }
```

**Validation:** for `AnalysisStore`, temporarily force a `SwingError` (e.g. a corrupt/tiny synthetic
clip, once #2 makes this throw instead of crash) and confirm `dest` doesn't linger in
`AppPaths.videosDir` afterward. For `autoTrim`, run a normal on-device capture and confirm the temp
directory doesn't accumulate a `cap-*.mov` alongside every `trim-*.mov` after a successful trim.
No regression: normal successful import/analyze still plays back and appears correctly in History.

---

### 17. `BagStore` treats SwiftData fetch failures identically to "no data"
**File:** `ios/Divot/Store/BagStore.swift:12-19` (`seedDefaultBagIfEmpty`), `32-56`
(`migrateLegacySessions`)

**Problem:** `(try? context.fetch(...)) ?? ([]/0)` makes a transient SwiftData error look identical
to "genuinely empty," risking duplicate seeding or duplicate migrated rows.

**Fix design:** make both `throws` and propagate, since the caller (`ContentView.swift`'s `.task`)
already runs in an async context that can handle a thrown error:
```swift
static func seedDefaultBagIfEmpty(_ context: ModelContext) throws {
    let count = try context.fetchCount(FetchDescriptor<BagClub>())
    guard count == 0 else { return }
    for (i, spec) in Bag.sorted(Bag.defaultBag).enumerated() { context.insert(BagClub(spec: spec, order: i)) }
    try context.save()
}
```
Same shape for `migrateLegacySessions`. Real signature change — every call site needs updating
(`ContentView.swift`, plus ~10 existing test call sites in `AppValidationTests.swift` that already
run inside `throws` test functions — the mechanical update is adding `try` in front of each call).

**New tests:** SwiftData doesn't offer an easy way to force `fetchCount`/`fetch` to throw in-memory,
so validate the *contract* change itself (the function now makes silent-empty-on-error impossible by
construction) rather than manufacturing a real I/O failure — the existing
`testSeedDefaultBagIsIdempotent` remains the main regression guard.

**Validation:** (a) code-review-level confirmation that no `try?`/`?? []` remains in these two
functions. (b) `make test` — all existing Bag-related tests (8+) still pass with `try` call-site
updates; manual Simulator check (delete app, reinstall) confirms the default 11-club bag still
seeds correctly on first launch.

---

## Medium

- **`MotionTrigger.swingWindow` has no hysteresis** (`MotionTrigger.swift:22-25`) — the
  window-expansion loop stops at the first sub-threshold sample. **Fix:** require a minimum
  run-length below threshold before declaring a boundary, via a new defaulted `debounceSeconds`
  parameter:
  ```swift
  let debounce = max(1, Int(debounceSeconds * fps))
  while start > 0 { let lo = max(0, start - debounce); if sm[lo...start].allSatisfy({ $0 <= thresh }) { break }; start -= 1 }
  // symmetric for `end`
  ```
  **Test:** extend `[MotionTrigger]` with a one-frame dip inside an otherwise-clean burst; confirm
  `startIdx` isn't truncated early. **Validation:** fails before the fix, passes after; the two
  original `[MotionTrigger]` checks (clean burst, flat series → nil) unaffected since debounce only
  changes behavior in the presence of a dip.

- **`Faults.swift` threshold/severity math has no direct unit test** — only exercised indirectly via
  one golden fixture. **Fix:** test-only, no production change. Add `[Faults synthetic]`, driving
  values from `Benchmarks.defaults` itself (not hardcoded numbers) so the test can't silently drift:
  for each `def`, construct a `SwingMetrics` at exactly `def.fault` (must not fire — strict
  `>`/`<`), just past it (must fire, severity in `(0,1]`), and far past it (severity clamps to
  `1.0`); also test override application directly (a `weightLeadPctEst` of 62 must not fire
  `hanging_back` under `.driver`'s override but must under `.wedge`'s default). Recommend adding
  `CaseIterable` to `Angle` (zero-risk, matches `Hand`/`Joint`/`Phase` already being `CaseIterable`)
  to make the "wrong angle family never fires" case constructible without hardcoding the enum by
  hand. **Validation:** `make validate` — pre-existing `[Faults]`/`[Benchmarks]` sections untouched.

- **`JointSeries` rebuilt redundantly 5-12× per swing/screen load** — additive refactor: add
  `JointSeries`-accepting overloads alongside the existing `PoseSequence`-taking ones
  (`EventDetector.detect(_ series:, hand:)`, `MetricsEngine.compute(_ series:, ...)`,
  `PlaneEngine.analyze(_ series:, ...)`, `SwingLines.lines(_ series:, ...)`), with existing
  signatures becoming thin wrappers. `SwingAnalyzer.analyze(_ pose:)` builds `let series =
  JointSeries(pose)` once and threads it through every downstream call. **Validation:** output is
  unchanged by construction — run `make validate` before/after and diff the log line-by-line; every
  `approx()` value must be byte-identical, since this refactor is explicitly supposed to be a no-op
  on output. Any difference means a call site was threaded with the wrong `hand`/`angle`.

- **`switchCamera` can silently fail both primary and fallback camera add**
  (`CaptureController.swift:93-104`) yet still reports the old camera position as current. **Fix:**
  add `@Published var cameraUnavailable = false`, set it when both `addCameraInput` calls fail, and
  give `CaptureView` a small `ContentUnavailableView` overlay matching the existing
  `permissionDenied` pattern. **Validation:** T3 manual only (requires simulating camera
  unavailability, e.g. another app holding the camera) — acceptable as a defensive fix validated by
  code inspection plus best-effort manual repro.

- **`ImportView` detection tasks have no cancellation token** (`ImportView.swift:108-159`) — tag each
  detection with the URL it targets and discard mismatched results:
  ```swift
  guard pickedURL == url else { return }   // a newer selection has since replaced this one
  ```
  Cheaper than `Task` handle/cancellation plumbing, matches the file's terse style. **Validation:**
  not practically reproducible in XCTest (a UI-timing race needing two near-simultaneous picks) —
  validate manually by picking two clips in quick succession and confirming state reflects the
  second (current) selection.

- **Live-capture Vision objects reallocated every frame with no in-flight guard**
  (`CaptureController.swift:114-133`) — add a simple in-flight guard rather than restructuring
  around `VNSequenceRequestHandler`:
  ```swift
  guard frameCounter % 3 == 0, !visionBusy else { return }
  visionBusy = true; defer { visionBusy = false }
  ```
  Safe without atomics since `captureOutput` runs synchronously to completion on `capture.frames`
  before the next callback fires. **Validation:** T3 manual — profile capture-frame throughput via
  Instruments before/after during a 240fps recording, confirm no regression in frame drop rate.

- **Widespread `try? context.save()` silently swallows persistence errors** (`BagEditor.swift`,
  `MLM2ProOverride.swift`, `ImportView.swift`) — mirror the #17 fix: make `BagEditor`'s mutation
  functions `throws` and propagate; at each SwiftUI call site, catch and reuse the
  `@State private var error: String?` + `Text` pattern `ImportView` already has (`ImportView.swift:99-101`)
  rather than inventing a new UI idiom. **Validation:** `make test` after updating throwing
  signatures — existing 8+ Bag tests already run inside `throws` test functions, so most call sites
  need only `try` added; code-review confirmation that no bare `try?` remains on user-initiated data.

- **`BallDetector.detectAtAddress` always allocates/scans a full-resolution buffer**
  (`BallDetector.swift:14-19`) — the only call site (`FrameExtractor.swift:72`) always passes
  `footRegion: nil`. **Fix:** derive a real region from the address-frame pose (ankles are already
  available via `nearestFrame`, called a few lines later — call it slightly earlier):
  ```swift
  private static func ballSearchRegion(_ frame: PoseFrame) -> CGRect? {
      let ankles = [frame.joints[.leftAnkle], frame.joints[.rightAnkle]].compactMap { $0 }
      guard !ankles.isEmpty else { return nil }
      let midX = ankles.map(\.x).reduce(0, +) / Double(ankles.count)
      let footY = ankles.map { 1 - $0.y }.max() ?? 0.9
      return CGRect(x: max(0, midX - 0.3), y: max(0, footY - 0.05),
                    width: min(1, midX + 0.3) - max(0, midX - 0.3), height: min(1, footY + 0.25) - max(0, footY - 0.05))
  }
  ```
  This cuts the *scan* cost at the call site; the allocation/draw cost itself needs a
  `BallDetector`-internal fix (crop the `CGImage` via `image.cropping(to:)` before building the byte
  buffer when `footRegion` is non-nil) — a ~33MB→small-crop win, best paired with the SwingCore-side
  test-coverage additions for `BallDetector`. **Test:** make `ballSearchRegion` non-private, assert
  it returns a sane bounded rect for a synthetic `PoseFrame` and `nil` when ankles are absent.
  **Validation:** `make test`; manual confirmation that ball auto-detect on the seeded sample clip
  still lands correctly, just cheaper.

- **`SideBySideView` seeks before player items are ready** (`SideBySideView.swift:84-98`) — `seek()`
  called synchronously right after `replaceCurrentItem`, before `.readyToPlay`. **Fix:** move item
  assignment to `.onAppear`, wait for readiness in the existing `.task` before seeking (plain polling
  loop, no Combine — matches the app's dependency-free style):
  ```swift
  private func waitUntilReady(_ player: AVPlayer) async {
      guard let item = player.currentItem else { return }
      for _ in 0..<50 {
          if item.status == .readyToPlay || item.status == .failed { return }
          try? await Task.sleep(nanoseconds: 100_000_000)
      }
  }
  ```
  **Validation:** manual — open Compare → Side by side several times (including cold-launch) and
  confirm both players start at the event-aligned frame, not frame 0, every time.

- **`SideBySideView.computeMatch`'s `Task.detached` doesn't inherit cancellation**
  (`SideBySideView.swift:101-114`) — `SideBySideView` is a plain, non-`@MainActor` struct, and none
  of `PoseEstimator.pose`/`TemplateBuilder.build`/`PoseComparator.compare` are actor-isolated, so
  `Task.detached` was never actually necessary. **Fix:** remove the detach, check `Task.isCancelled`
  before applying results, so the work is part of the parent's structured `.task`. Land together
  with #13's cache call-site change (same lines). **Validation:** manual — open Side-by-side,
  navigate back before "Shape match" resolves, confirm (via a temporary log or Instruments) work
  stops promptly rather than finishing in the background after dismissal.

- **Toggle "chip" controls convey state by color only** (`GhostCompareView.swift:43-58`,
  `DTLPlaneView.swift:87-113`, plus `SwingPlayerView`'s rate buttons covered under #14) — one-line
  addition at each: `.accessibilityAddTraits(bind.wrappedValue ? .isSelected : [])`. **Test:** extend
  the #14 audit-navigation additions to tap a chip and assert `app.buttons["Shoulders"].isSelected`
  after tapping (`XCUIElement.isSelected` reflects the trait directly). **Validation:** `make test`.

### SwingCore engine test-coverage gaps

All go into `SwingCoreCheck/main.swift` in the same `[Bracket]`/`check()`/`approx()` idiom, inserted
immediately after their existing same-named section. **Shared validation methodology:** after
adding a block, run `make validate` and confirm the printed count increased by exactly the number
of new checks; to confirm non-vacuousness, temporarily perturb the relevant guard/threshold, re-run,
confirm the new check fails, then revert.

- **`EventAlignment.mapTime`'s zero-denominator case** (two adjacent events sharing a timestamp) —
  assert it maps to the interval's start with no crash/NaN, not garbage.
- **`SequenceEngine.compute`'s `n<3` guard, `hi`/`lo` clamping near sequence end, and `hand: .left`**
  — the last of these matters most: left-handed golfers are completely untested end to end today,
  compounding finding #7. Add a mirrored `seqPoseLeft` fixture (reads right-side arm/hand joints)
  and confirm `inSequence` still resolves correctly.
- **`AngleDetector.detect`'s degenerate-geometry (`torsoH <= 1`) and partial-joint-missing branches**
  — coincident shoulders/hips and hips-entirely-undetected fixtures, both should default to
  `.faceOn`/confidence 0 without crashing.
- **`PoseEstimator.pose(video:)`'s error-throw path** — feed a nonexistent file path, assert
  `SwingError.unreadableVideo` carrying the offending URL.
- **`MLM2ProCSV.parse`'s embedded-newline-in-quoted-field case** — this one should be added as a
  check that **pins the current (buggy) behavior** (3 rows instead of the correct 2), with a comment
  pointing at the Low-priority fix below; once that fix lands, flip the assertion to the corrected
  2-row expectation.
- **`ClubTracker.path` with 100%-gap (all-nil) detections** — assert empty `points`, `coverage == 0`,
  not garbage.
- **`BallDetector.detectAtAddress` with multiple bright blobs** — two separated circles should fail
  the circularity gate and return `nil` (combined bounding box won't be circular). Partial-occlusion
  case: capture the actual returned value empirically (same method the file's other golden values
  were originally produced with) rather than guessing a number.
- **`Segmenter.swings(in:)` with a synthetic multi-swing clip** — two well-separated bursts (4s
  apart) should produce 2 windows in time order; two close bursts (1s apart, inside default
  `minSep`) should collapse to 1.
- **`PlaneEngine.analyze`'s degenerate/empty-path guard** — empty `clubPath` should give
  `overTheTop == false`, `maxAbovePlane == 0`, `source == "club"` (not silently falling back to hand).
- **`Trends`'s NaN-filtering and `rollingMean`'s window clamping** — a NaN metric value must be
  filtered out of the series; `window: 0` and negative windows must clamp to 1 without crashing.
- **`FramingGuide.inFrame`'s extent-ratio bounds and no-head branch** — `extent < 0.45` → "too
  small," `extent > 0.97` → "too close," mid-range → ok, no nose/ear at all → the specific
  "Get your head in frame" message.
- **`ReportBuilder.markdown`'s no-swing-detected branch** — empty `swings` array still renders the
  fallback text and the header/club line.
- **`BallFlightTracer.link`'s single-point case** (returned unchanged) and **reverse-flight case**
  (right-to-left shot) — the latter should be added as a check documenting the **known gap**
  (`link` always sorts ascending-x regardless of true direction, so a right-to-left shot is
  reordered backwards in time) rather than asserting "correct" behavior, matching the Low-priority
  fix below which makes direction an explicit parameter.

### UI-test `sleep()` → readiness-wait fix
**Files:** `ios/DivotUITests/AccessibilityAuditTests.swift`, `ios/DivotUITests/ScreenshotTour.swift`

**Problem:** fixed `sleep(1-3)` calls gate every screenshot/audit instead of waiting for actual
content to render — a slower render than the hardcoded sleep produces a false-green audit against a
still-loading/empty screen.

**Fix design:** `ScreenshotTour.swift` already has the correct pattern in one spot:
`app.cells.firstMatch.waitForExistence(timeout: 30)` before the History screenshot. Replace every
other fixed sleep with the same style of wait on that tab's actual content — a generic
`app.navigationBars.firstMatch.waitForExistence(timeout: 10)` at minimum for tabs without a more
specific identifier, `app.cells.firstMatch.waitForExistence(timeout: 10)` for History (mirroring
`ScreenshotTour`'s own already-correct wait so the two files converge on the same signal for the
same screen), and a stable per-screen identifier where cheaply available for Trends/Compare/Settings
(needs a quick check of those view files before finalizing exact identifier strings). Extract the
shared "wait for this tab's content" helper into one place both test files call.

**Validation:** since this changes test infrastructure, validate by deliberately slowing a screen's
render (e.g. temporarily add `Thread.sleep(forTimeInterval: 5)` in that screen's `.onAppear`) and
confirming the old `sleep(N)`-based test still passes falsely (proving the gap), while the new
`waitForExistence`-based version either correctly waits and passes or times out and fails loudly —
then revert the artificial delay. Doesn't change test count (still 2 UI tests), only reliability.

---

## Low

- **Duplicated force-unwrap `Joint(rawValue:)!` helper** (`Analysis.swift:78`, `SwingLines.swift:25`,
  `SequenceEngine.swift:24`) — consolidate into `Models.swift` with a safe fallback instead of a
  crash: `extension Joint { static func bySideAndPart(_ side: String, _ part: String) -> Joint {
  Joint(rawValue: side + part) ?? .leftWrist } }`. **Test:** valid combination resolves correctly;
  invalid combination falls back instead of crashing. **Validation:** temporarily revert to the old
  `!`-based helper, confirm it traps on the invalid-combination test input; re-apply, confirm it
  passes.

- **`FramingGuide.inFrame` force-unwraps ankles on an unenforced invariant** (`FramingGuide.swift:26`)
  — replace with `guard let`, matching the file's own style two lines earlier. Not independently
  testable today (currently unreachable through `inFrame`'s public API since `required` already
  includes both ankles) — this is defense-in-depth against a future edit to `required`.

- **`BallFlightTracer.link` infers direction purely from x-position** (`BallFlightTracer.swift:20-23`)
  — add a `leftToRight: Bool = true` parameter (default preserves all existing behavior):
  `let sorted = pts.sorted { leftToRight ? $0.x < $1.x : $0.x > $1.x }`. **Test:** extend `[ClubPath]`
  with a right-to-left fixture using `leftToRight: false`, assert x is non-increasing.

- **`MLM2ProCSV` splits on raw newlines before quote-aware parsing** (`MLM2ProCSV.swift:31-33`) —
  make line-splitting itself quote-aware (toggle an `inQuotes` flag while scanning for line
  boundaries; doesn't need to fully replicate `fields`'s escaped-`""` handling, only needs correct
  boundaries). Read `ios/DivotTests/Fixtures/sample_shots.csv`'s actual header/column order before
  writing the new test row. Once this lands, flip the pinned-bug test-coverage check above from
  3-rows to the corrected 2-rows expectation.

- **No explicit file-protection class on stored video/session data** — bundle
  `rv.fileProtectionType = .completeUnlessOpen` into the same `AppPaths.videosDir` fix as #12 (same
  `setResourceValues` call).

- **`CaptureController` has no `deinit`/explicit delegate clearing** — add
  `deinit { sessionQueue.sync { videoOutput.setSampleBufferDelegate(nil, queue: nil); if session.isRunning { session.stopRunning() } } }`
  as a backstop. **Validation:** T3, via Instruments' Allocations/Leaks — confirm dismissing
  `CaptureView` repeatedly doesn't accumulate retained `CaptureController` instances.

- **`AnalysisStore.analyze` has no internal re-entrancy guard** — add `guard !busy else { return nil }`
  as the first line. Genuinely race-free once added since `AnalysisStore` is `@MainActor` (reads/writes
  of `busy` are already actor-serialized), unlike the `CaptureController` cases.

- **`HapticsPlayer`'s `CHHapticEngine` setup failure is swallowed with no logging** — change the
  empty `catch {}` to at least `os_log`/`print` the error; no user-visible behavior change.

- **`SwingPlayerModel.init` reads `asset.duration`/`asset.tracks` synchronously** (deprecated
  blocking `AVAsset` calls during `NavigationLink` push) — make `duration`/`nominalFrameRate`/a new
  `aspectRatio` `@Published private(set)` with harmless defaults, populate via the async `load(_:)`
  API in a `loadMetadata()` called from `.task {}` (matching the existing `.task { await load() }`
  idiom elsewhere in the view layer). Also folds in the fixed-9:16-aspect-ratio Low item: change
  `.aspectRatio(9.0/16.0, contentMode: .fit)` to `.aspectRatio(model.aspectRatio, contentMode: .fit)`,
  derived from the track's `naturalSize`/`preferredTransform`. **Test:** confirm `loadMetadata()`
  populates `duration > 0` and a sane `aspectRatio` for the repo's synthetic fixture clip.

- **`ResultsView`'s share/GIF-export tasks aren't cancelled on dismiss** — store the `Task` handle,
  cancel in `.onDisappear`, check `Task.isCancelled` before presenting the share sheet.

- **`CSVImportView` does a synchronous main-thread file read** — wrap `handle(_:)`'s body in a
  `Task`, keep the security-scoped-resource start/stop paired within it, use
  `Task.detached(priority: .userInitiated)` for the actual `String(contentsOf:encoding:)` call.

- **`TrendsView`'s chart series are distinguished only by color for VoiceOver** — add
  `.accessibilityLabel("Reference")`/`.accessibilityLabel("Your trend")` to the respective
  `PointMark`/`LineMark` (Swift Charts supports this natively). No automated assertion is
  practical here (XCUITest can't deeply inspect individual Chart-mark accessibility elements) —
  verify manually with VoiceOver enabled.

---

## Suggested order of attack

1. **#1 first, always.** The CI/validation harness path fix needs to land before anything else, so
   every subsequent fix in this doc gets a working regression gate instead of a mostly-silent one.
2. **#15 (CaptureController testability) before #3/#4/#8/#9.** The `LiveSwingTrigger` extraction is
   shared groundwork for the auto-stop hang, the teardown fix, and the concurrency/queue-mirroring
   pass — do the extraction once, then land #3/#4/#8/#9 together as one coherent concurrency pass
   over `CaptureController` (they touch overlapping lines).
3. **#5 (orientation) after #9**, since its fix reads the post-#9 queue-confined `currentPosition`
   rather than the current cross-thread `@Published` read.
4. **#2 and #6 together** (both are guards added to the same `SwingAnalyzer.analyze(_ pose:)` entry
   point, both use the same new `[Pipeline degenerate]` test bracket).
5. **#7 (left-handed plane sign)** — independent, but pairs naturally with the SequenceEngine
   `hand: .left` test-coverage addition, since both close the same "left-handed golfers untested
   end to end" gap.
6. **#13 (pose caching) together with the SideBySideView `Task.detached` fix** — same lines.
7. Everything else in High, then Medium, then Low, roughly in listed order — none of the remaining
   items block each other.
8. **Test-coverage-only additions** (the SwingCore engine gaps, the UI sleep→readiness fix) can be
   done incrementally at any point after #1, since they don't depend on any of the other fixes
   landing first — but do them close to whichever fix they document (e.g. add the CSV
   embedded-newline pinned-bug check when you're already touching `MLM2ProCSV.swift` for its Low-
   priority fix).

Each step above should end with `make validate` (and `make test` for anything touching `ios/`)
showing the check/test count increased by exactly what that step added, and no prior check
regressing.
