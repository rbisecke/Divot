# Divot — Aggregated Code Review Findings

Six parallel specialist reviews covering the whole repo: security/privacy, SwingCore engine
correctness, iOS store/controller concurrency, SwiftUI views, performance, and test coverage.
Findings below are merged, de-duplicated where two reviews hit the same bug from different
angles, and ranked by actual impact. Nothing here has been fixed yet — this is a punch list.

Severity key: **Critical** = crash, hang, data loss, or silently-wrong swing analysis with no
error surfaced. **High** = real bug with a plausible trigger, or a meaningful security/privacy/
accessibility gap. **Medium** = quality/robustness issue or silently-swallowed error. **Low** =
polish, latent assumption, or minor hygiene.

---

## Critical

### 1. CI's "176 golden checks" mostly don't run — the T1 regression gate is close to a no-op
**Files:** `SwingCore/Sources/SwingCoreCheck/main.swift` (all `SWINGCORE_TEST_*` fallback paths),
`SwingCore/validate.sh`, `.github/workflows/ci.yml`

Every substantive check block (`[Pose]`, `[Segment]`, `[Events]`, `[Metrics]`, `[Faults]`,
`[Reference]`, `[Pipeline]`, `[Benchmarks]`, `[SwingLines]`, `[AngleDetector]`, `[MLM2ProCSV]`,
`[Replay]`, etc.) is gated on `FileManager.fileExists` against default paths that point *outside
this repo* — `/Users/rbisecke/Downloads/golf_vids/auto/swing_1.mov` and a path inside an unrelated
sibling project (`golfing/swing-analyzer/...`). `validate.sh` (run by `make validate` and CI's
`engine` job) never sets the `SWINGCORE_TEST_*` env vars to point at the fixtures that actually
exist in this repo (`ios/DivotTests/Fixtures/sample_swing.pose.json`, `sample_shots.csv`). Every
gated block prints `⊘ skipped`, never `ALL PASS`/count, and both `validate.sh` and CI only
`grep -q "ALL PASS"` — there's no check on *how many* checks ran. Net effect: on a clean clone or
in CI, the numeric/regression-heavy majority of "176 checks" never executes, and CI still goes
green. This is very likely why bugs #2, #6, and #7 below shipped undetected.

**Fix:** point the harness's default fallback paths at the repo's own committed fixtures, and
make it assert (or CI check) a minimum expected check count so a mass-skip fails loudly instead
of silently.

*(Found independently by both the engine-correctness and test-coverage reviews.)*

### 2. Crash analyzing a very short or partially-corrupt clip (index out of range)
**File:** `SwingCore/Sources/SwingCore/Analysis.swift:49` (`argmax`), reached via
`EventDetector.detect` (`Analysis.swift:62-66`) and `SwingAnalyzer.analyze(video:)`
(`Pipeline.swift:27-29`)

`iHi = max(2, min(n, Int(0.92*Double(n))))` evaluates to `2` even when `n` (frame count) is `0`
or `1`, so `argmax`/`argmin` index into a 0- or 1-length array up to index 1 → fatal
out-of-range crash. `SwingAnalyzer.analyze(video:)` has no minimum-frame guard before this (unlike
`analyzeSession`, which does check `>= 5`), and `PoseEstimator.pose` can legitimately return a
1-frame or 0-frame sequence for a very short or partially unreadable clip (per-frame image copy
can silently fail and `continue`).

**Trigger:** user records or imports a clip too short (or too corrupt) for Vision to get enough
frames. App crashes instead of showing "clip too short."

**Fix:** guard `pose.frames.count >= 5` (matching `analyzeSession`'s threshold) at the top of
`EventDetector.detect` or `SwingAnalyzer.analyze(_ pose:)`, throwing `SwingError` instead of
falling through to the indexing math.

### 3. Live auto-stop can hang forever, with no way to end the recording
**File:** `ios/Divot/Store/CaptureController.swift:135-146` (`detectMotion`),
`ios/Divot/Views/CaptureView.swift` (no manual stop control)

`detectMotion` bails out immediately (`guard let y = leadWristY else { return }`) whenever lead-
wrist Vision confidence drops below 0.15 — and in that branch `settleCounter` (the thing that
eventually calls `endRecording()`) is never touched. Motion blur on the lead wrist is most likely
during and right after the downswing, i.e. exactly the moment this feature exists to capture.
`CaptureView` has no manual stop button (only Cancel), so a swing that blurs the wrist tracking
can leave the user stuck in an indefinite recording with no way to end it except backing out —
which triggers bug #4.

**Fix:** add a hard time/frame ceiling that force-stops regardless of wrist-tracking confidence,
and/or add a manual stop affordance.

### 4. Backing out of a stuck/in-progress recording corrupts or orphans the video file
**Files:** `ios/Divot/Store/CaptureController.swift:110` (`stop()`) vs. `148-158`
(`endRecording()`); `ios/Divot/Views/CaptureView.swift:79` (`.onDisappear { cap.stop() }`)

`stop()` only calls `session.stopRunning()` — it never checks `movieOutput.isRecording` or calls
`movieOutput.stopRecording()` first (unlike `endRecording()`, which does this correctly on a
natural motion-settle). If the capture view disappears (user backs out, especially via bug #3's
stuck-recording scenario, or the app backgrounds) while `AVCaptureMovieFileOutput` is mid-write,
the session is yanked out from under it — the `didFinishRecordingTo` delegate callback may never
fire, leaving a truncated/corrupted `cap-<uuid>.mov` orphaned in the temp directory indefinitely
(nothing in the codebase cleans these up).

**Fix:** in `stop()`, if `movieOutput.isRecording`, call `movieOutput.stopRecording()` (and
optionally delete the in-flight file on an explicit cancel) before `stopRunning()`.

*(Found independently by both the app-layer and SwiftUI-views reviews.)*

### 5. Live pose tracking hardcodes `.up` orientation — likely root cause of trigger/framing misfires in normal (portrait) use
**File:** `ios/Divot/Store/CaptureController.swift:118-120`

`VNImageRequestHandler(cmSampleBuffer:orientation: .up, ...)` is hardcoded for every live frame.
Confirmed by repo-wide grep: nothing anywhere sets `videoOrientation`/`videoRotationAngle` on the
capture connection. `AVCaptureVideoDataOutput` delivers buffers in the sensor's native (landscape)
orientation; held portrait — the only realistic way to record a golf swing — Vision is analyzing
a frame rotated 90° from what it assumes. Since `CaptureView` has no manual record button, the
entire auto-trigger/framing feature depends on this being correct: joints get read at rotated
coordinates, so `framingOK` and the motion-trigger's wrist-Y span check can both fire on bogus
data — recording may never start, or start/stop at the wrong times.

**Fix:** derive the correct `CGImagePropertyOrientation` from the capture connection's actual
rotation/mirroring state (and camera position, for front-camera mirroring) instead of a constant.

### 6. Analysis silently produces garbage events when a tracked joint is never detected — the error case built for this is dead code
**Files:** `SwingCore/Sources/SwingCore/PoseEstimator.swift:57-68` (`SwingError.lowPoseConfidence`
is defined but never thrown anywhere in the repo), `Analysis.swift:49-50` (`argmax`/`argmin`),
`Models.swift` (`PoseSequence.framesDetected`, also never read anywhere)

If the tracked lead-wrist joint is undetected across an *entire* clip (occluded, out of frame,
bad angle), `JointSeries.interp` has no anchor to fill from, so that joint's series stays all-NaN.
Since `NaN > x` and `NaN < x` are both always `false` in Swift, `argmax`/`argmin` never update
past their initial index — `address`/`top`/`impact` deterministically collapse to fixed,
meaningless frame indices. No crash, no error: the full pipeline (metrics, faults, comparison,
plane, sequence) runs on this garbage and presents it to the user as a legitimate analysis.

**Fix:** check that the tracked lead joint has a meaningful detection ratio (or use the already-
defined `framesDetected`) and throw `SwingError.lowPoseConfidence` instead of proceeding — this is
exactly the case that error case exists for.

---

## High

### 7. Over-the-top/shallow plane classification is sign-flipped for left-handed golfers
**File:** `SwingCore/Sources/SwingCore/PlaneEngine.swift:32-37`

The swing-plane normal uses a fixed 90° rotation (`nx = -dy/len, ny = dx/len`); joint *selection*
is hand-aware elsewhere in the file, but this sign isn't. Hand-verified algebraically: mirroring
the same swing geometry (which is what a lefty's swing looks like relative to a righty's, filmed
from the same camera side) flips the sign of `dev`, so a genuine over-the-top move gets classified
as shallow and vice versa. Zero test coverage exists for `hand: .left` anywhere in the golden-check
harness for this code path.

**Fix:** derive the normal's sign from actual swing geometry (e.g. relative to the hand-aware
trail shoulder) instead of a fixed rotation; add a `hand: .left` synthetic test case.

### 8. No serialization between camera reconfiguration and recording start/stop
**File:** `ios/Divot/Store/CaptureController.swift:32-34, 93-104, 148-158`

`switchCamera()`/`configure()` run on `sessionQueue`; `beginRecording()`/`endRecording()` run on
the separate `capture.frames` delegate queue, mutating the same `AVCaptureSession`/`movieOutput`
with no shared lock. `switchCamera()`'s own `!movieOutput.isRecording` guard is checked on one
queue while recording can start on the other microseconds later — a known source of
`AVCaptureSession` crashes/corrupted output when session reconfiguration races an active recording.

**Fix:** funnel recording start/stop through `sessionQueue` like every other session mutation.

### 9. `@Published` capture state read cross-thread with no synchronization
**File:** `ios/Divot/Store/CaptureController.swift:129-133` (`dtlMode`), `140-145` (`isRecording`),
`74/99-100` (`cameraPosition`)

`dtlMode` and `cameraPosition` are written on main (SwiftUI bindings) but read on the frame/session
queues inside `captureOutput`/`switchCamera`; `isRecording` is written via
`DispatchQueue.main.async` but read directly (not `movieOutput.isRecording`) on the frame queue, so
it can lag several frames behind reality. This is a genuine data race under Swift's memory model —
worst case, flipping Face-on/DTL mid-session evaluates the framing guide against the wrong mode for
a frame or two.

**Fix:** keep a queue-confined shadow copy for anything read off-main, or mark the controller
`@MainActor` and hop explicitly for the Vision/frame work.

*(Found independently by both the app-layer and SwiftUI-views reviews.)*

### 9b. Vision joint confidence is captured, then never used downstream
**File:** `SwingCore/Sources/SwingCore/PoseEstimator.swift:46-47` (`JointPoint.c` written) vs.
`Analysis.swift:22` (only `.x`/`.y` read) — confirmed via repo-wide search, `.c` is read nowhere.

Once a joint clears the flat `minConfidence: 0.15` cutoff, a detection at confidence 0.16 is
weighted identically to one at 0.99 in every downstream smoothing/interpolation/metric. A noisy,
barely-passing sample (e.g. a wrist blurred through impact) silently degrades event detection and
every biomechanical metric with no signal to the user.

**Fix:** thread confidence through `JointSeries` so low-confidence samples are down-weighted or
excluded rather than treated as ground truth.

### 10. Tap-to-set-ball-position doesn't account for the renderer's own letterboxing — anchors to the wrong point
**File:** `ios/Divot/Views/DTLPlaneView.swift:47-58` + `ios/Divot/Rendering/SkeletonCanvas.swift:29-51,115-119`

The tap gesture normalizes against the raw `GeometryReader` size, but `SkeletonCanvas` internally
letterboxes the image (`aspectFit`) into a smaller centered sub-rect and draws relative to *that*.
The gesture never replicates the same math. Whenever the container's aspect ratio doesn't exactly
match the clip's (essentially always, given the surrounding banner/label/controls), the ball
anchor lands visibly offset from where the user actually tapped — the same class of
coordinate-space bug this project has hit before.

**Fix:** compute (or expose from `SkeletonCanvas`) the same `aspectFit` sub-rect and map the tap
through it before normalizing.

### 11. Real signing secrets sit in untracked directories with no explicit gitignore protection
**Files:** `.claude/worktrees/<agent-*>/ios/Config/Signing.local.xcconfig`,
`.../embedded.mobileprovision` (17 stray agent worktrees present)

Real `DEVELOPMENT_TEAM` (Team ID), Team Name, bundle ID, and two real device UDIDs exist in these
paths today. They're currently safe only because each is a git worktree (its own gitlink), which
makes `git add -A` refuse to ingest the file contents — not because `.gitignore` (which never
lists `.claude/worktrees/`) is doing anything. If a worktree is ever cleaned up by deleting `.git`
first, or `git add -f` is used, or the harness stops nesting these as worktrees, this becomes a
direct violation of the project's hard rule against committing Team IDs/provisioning profiles.

**Fix:** add `.claude/worktrees/` to the root `.gitignore` explicitly; clean up the 17 stray
worktrees.

### 12. Swing video and analysis data aren't excluded from iCloud device backup
**Files:** `ios/Divot/Models/SavedSession.swift:58-67` (`AppPaths.videosDir`),
`ios/Divot/Store/AnalysisStore.swift:19`

Nothing sets `isExcludedFromBackup` anywhere in `ios/`. Files under `Documents/` are backed up to
iCloud by default. CLAUDE.md/SECURITY.md both assert "video never leaves the phone," but if the
user has iCloud Backup enabled, raw swing video and pose/metrics data leave the device via Apple's
own backup pipeline — a real gap between the stated privacy model and actual behavior.

**Fix:** set `isExcludedFromBackup = true` on the videos directory (and SwiftData store, if
desired) at creation time, or explicitly scope the "never leaves the phone" claim to exclude
device backups.

### 13. Pose estimation (full Vision re-run) is never cached — every review screen re-runs it from scratch
**Files:** `SwingCore/Sources/SwingCore/PoseProvider.swift`, `ios/Divot/Store/FrameExtractor.swift:58`,
`FrameExtractorMotion.swift:10`, `ios/Divot/Views/SideBySideView.swift:107-108`,
`ios/Divot/Store/CaptureController.swift:168`

`PoseEstimator.pose` (decode every frame + run Vision per frame, serially) is the single most
expensive operation in the app, and it's independently re-run — with zero caching — at capture
(`autoTrim`), at import/analysis, and again on *every visit* to Ghost, Motion, or Side-by-side.
Navigating Results → Ghost → back → Motion → back → Plane/path triggers three additional full
decode+Vision passes over a clip already fully analyzed once.

**Fix:** persist the computed `PoseSequence` alongside `SavedSession`, or cache it in memory keyed
by video URL for the current session, so review screens read from it instead of recomputing.

### 14. Accessibility: form fields and video-playback controls are unusable with VoiceOver
**Files:** `ios/Divot/Views/ShotDataForm.swift:39-42`, `ios/Divot/Views/SwingPlayerView.swift:102-142`

`ShotDataForm`'s `field()` helper passes an empty string as the `TextField` label (which doubles
as its accessibility label) — VoiceOver announces every measurement field as "text field, blank,"
with no indication which one it is. `SwingPlayerView`'s frame-step/play/pause buttons have no
`.accessibilityLabel`, and the hand-built scrubber (a bare `Capsule`/`DragGesture`) has no
accessibility element/value/adjustable action at all — a VoiceOver user cannot scrub video
playback by any means.

**Fix:** pass the real label into each `TextField`; add `.accessibilityLabel` to transport
buttons; wrap the scrubber with `.accessibilityElement` + `.accessibilityValue` +
`.accessibilityAdjustableAction`.

### 15. `CaptureController`'s live record/settle state machine has zero test coverage
**File:** `ios/Divot/Store/CaptureController.swift:135-146` (`detectMotion`), `beginRecording()`,
`endRecording()`

All of it is `private` and untestable from XCTest as written; only the two pure static helpers
(`framing`, `nextPosition`) are unit tested. This is exactly the stateful start/settle/stop logic
behind bugs #3 and #4, and it has never been exercised by an automated test — every prior fix in
this area has had to be validated manually on-device.

**Fix:** extract the pure window/threshold logic into a free function/testable struct (mirroring
`MotionTrigger.swingWindow`), and add headless tests for: a clean swing, a false-start that never
settles, back-to-back swings, and a session that never settles.

### 16. Orphaned files on disk: failed analysis and successful auto-trim both leak temp/permanent files
**Files:** `ios/Divot/Store/AnalysisStore.swift:14-33` (`analyze`),
`ios/Divot/Store/CaptureController.swift:166-183` (`autoTrim`)

`analyze()` copies the picked video into permanent `Documents/videos` *before* running analysis;
if analysis throws, the function returns `nil` but the copied file is never cleaned up. Separately,
every successful `autoTrim` publishes the trimmed clip but never deletes the original full-length
temp recording it was cut from — every auto-trim leaks one full-resolution recording into `tmp/`.

**Fix:** `try? FileManager.default.removeItem(at:)` on both the analysis failure path and after a
confirmed-good trim.

### 17. Fetch failures in `BagStore` are treated identically to "no data," risking duplicate seeding/migration
**File:** `ios/Divot/Store/BagStore.swift:12-19` (`seedDefaultBagIfEmpty`), `32-56`
(`migrateLegacySessions`)

`(try? context.fetchCount(...)) ?? 0` / `(try? context.fetch(...)) ?? []` make a transient
SwiftData error look identical to "empty." A transient fetch failure would cause
`seedDefaultBagIfEmpty` to insert a second default bag on top of an already-populated one, or
`migrateLegacySessions` to create duplicate `BagClub` rows alongside the real, unfetched ones.

**Fix:** distinguish a thrown fetch from a genuinely empty result; skip seeding/migration on error
for that launch rather than assuming empty.

---

## Medium

- **`MotionTrigger.swingWindow` has no hysteresis** (`SwingCore/Sources/SwingCore/MotionTrigger.swift:22-25`) — the window-expansion loop stops at the very first sample that dips below threshold, no debounce. A brief noise dip mid-swing can truncate the window before `address`/`finish` padding is applied.
- **`Faults.swift` threshold/severity math has no direct unit test** — only exercised incidentally via one golden fixture; boundary conditions (`v == fault`), severity clamping, angle-family filtering, and per-club `overrides` are all unverified in isolation.
- **`JointSeries` rebuilt redundantly 5–12× per swing/screen load** (`Analysis.swift`, `PlaneEngine.swift`, `SwingLines.swift`, `AngleDetector.swift`) instead of being built once and threaded through — pure wasted CPU on every analysis and screen load.
- **`BallDetector.detectAtAddress` always allocates/scans a full-resolution buffer** (`SwingCore/Sources/SwingCore/BallDetector.swift:14-19`) even though only a `footRegion` crop is needed; the only call site always passes `footRegion: nil`. ~33MB transient allocation on a 4K frame, repeated on every load and re-anchor tap.
- **Widespread `try? context.save()` silently swallows persistence errors** (`BagEditor.swift`, `BagStore.swift`, `MLM2ProOverride.swift`, `ImportView.swift`) — UI shows success even when the write to disk failed; user only discovers the loss on next launch.
- **`SideBySideView` seeks before player items are ready** (`SideBySideView.swift:84-98`) — `seek()` called synchronously right after `replaceCurrentItem`, before `.readyToPlay`; the initial event-aligned seek can silently no-op, leaving both players on frame 0.
- **`SideBySideView.computeMatch` uses `Task.detached` inside a cancellable `.task`** (`SideBySideView.swift:101-114`) — the detached child doesn't inherit parent cancellation, so backing out immediately still burns CPU/battery running the full pose/compare pipeline to completion in the background.
- **Toggle "chip" controls convey state by color only** (`GhostCompareView.swift:43-58`, `DTLPlaneView.swift:87-113`, `SwingPlayerView.swift:132-139`) — no `.accessibilityAddTraits(.isSelected)`/value, same label announced regardless of on/off state.
- **`switchCamera` can silently fail both primary and fallback camera add** (`CaptureController.swift:93-104`) yet still reports the old camera position as current — preview goes black/frozen with no error surfaced.
- **`ImportView` detection tasks have no cancellation token** (`ImportView.swift:108-159`) — picking a second clip before the first's detached detection finishes can let the stale result overwrite state for the now-current selection.
- **Live-capture Vision objects reallocated every frame with no in-flight guard** (`CaptureController.swift:114-133`) — fresh `VNImageRequestHandler`/request/dictionary every 3rd frame, up to ~80×/sec at 240fps; on a thermally-throttled device this can lag the motion-trigger exactly when precision matters most.
- **Test coverage gaps in SwingCore's stateful/numeric logic** (see full list from the test-coverage review): `EventAlignment.mapTime`'s zero-denominator case, `SequenceEngine.compute`'s `n<3`/clamping/`hand:.left` paths (left-handed golfers are completely untested end to end, compounding finding #7), `AngleDetector`'s degenerate-geometry branch, `PoseEstimator`'s error-throw path, `MLM2ProCSV`'s embedded-newline case, `ClubHeadTrace` with 100%-gap detections, `BallDetector` with multiple bright blobs, `Segmenter.swings` with a synthetic multi-swing clip, `PlaneEngine`'s degenerate/empty-path guard, `Trends`'s NaN-filtering and rolling-window edges, `FramingGuide`'s extent-ratio bounds, `ReportBuilder`'s no-swing-detected branch, `BallFlightTracer`'s single-point/reverse-flight cases.
- **UI tests rely on fixed `sleep()` instead of readiness waits** (`AccessibilityAuditTests.swift`, `ScreenshotTour.swift`) — can run the audit against a still-loading view and report green while missing real issues in the fully-rendered state.

---

## Low

- **Duplicated force-unwrap helper** `Joint(rawValue: side+part)!` copy-pasted in three files (`Analysis.swift:78`, `SwingLines.swift:25`, `SequenceEngine.swift:24`) — safe today only because every call site happens to pass matching literals; no compile-time safety against a future typo.
- **`FramingGuide.inFrame` force-unwraps ankle joints** (`FramingGuide.swift:26`) based on an unenforced invariant with a separate `required` array — safe today, but a live crash risk if that array is ever edited without updating this line.
- **`BallFlightTracer.link` infers trajectory direction purely from x-position**, no timestamp — a right-to-left flight (mirrored setup, some lefty captures) would be reconstructed in reverse temporal order. No visible-output impact today since it's just a polyline overlay, but it's a latent, undocumented assumption.
- **`MLM2ProCSV` splits on raw newlines before quote-aware field parsing** — a quoted field with an embedded newline would be mis-split into two bogus rows. Low real-world likelihood given the export schema is short/numeric fields.
- **No explicit file-protection class on stored video/session data** — relies on iOS's default (`.completeUntilFirstUserAuthentication`) rather than an explicitly stronger class, despite the app framing this as sensitive body-pose data.
- **`CaptureController` has no `deinit`/explicit delegate clearing** — worth confirming `AVCaptureVideoDataOutput` doesn't retain its delegate in a way that keeps the camera session alive after the view is dismissed.
- **`AnalysisStore.analyze` has no internal re-entrancy guard** — correctness currently depends entirely on the calling view disabling its button while busy.
- **`HapticsPlayer`'s `CHHapticEngine` setup failure is swallowed with no logging at all** — a systemic haptics failure would be undiagnosable in the field.
- **`SwingPlayerModel.init` reads `asset.duration`/`asset.tracks` synchronously** — deprecated blocking `AVAsset` calls on main during `NavigationLink` push; can visibly hitch on a large/slow file.
- **Misc small items:** `ContentView`'s seed/migrate `.task` actor-safety on first launch is unconfirmed from the Views-only review scope; `ResultsView`'s share/GIF-export tasks aren't cancelled on dismiss; `CSVImportView` does a synchronous main-thread file read; `SwingPlayerView` assumes a fixed 9:16 aspect ratio regardless of actual clip orientation; `TrendsView`'s chart series are distinguished only by color for VoiceOver; `validate.sh` doesn't check `swift build`'s exit code before `swift run`; a few tests are intentional placeholders rather than real coverage (`testPose3DDeviceGated`, `testDockKitSupportFlagCompiles`, `ScreenshotTour` has no assertions by design).

---

## Suggested order of attack

1. Fix the CI/validation harness path issue (#1) first — it's why several of these bugs shipped
   undetected, and every subsequent fix needs a working regression gate to land safely against.
2. Critical capture-flow bugs together, since they compound: the orientation hardcode (#5) is
   plausibly *causing* the stuck-recording behavior (#3), which is only bad because of the
   teardown bug (#4).
3. The two silent-wrong-analysis bugs (#6 crash-adjacent NaN collapse, #7 left-handed plane sign)
   — these erode trust in the tool's core value proposition (accurate measurement) without ever
   surfacing an error.
4. Everything else in High, roughly in listed order.
