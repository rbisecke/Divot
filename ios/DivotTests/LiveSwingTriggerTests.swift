// Part of Divot. Regression coverage for CaptureController's live record/settle state machine
// (code-review-findings.md #15), extracted into SwingCore.LiveSwingTrigger so it's testable
// without AVFoundation/Vision. `testWristTrackingLostDuringSwingForcesStop` is the regression
// test for finding #3 (auto-stop could previously hang forever).
import XCTest
import SwingCore

final class LiveSwingTriggerTests: XCTestCase {

    // A burst sample (0.75, 0.45) stays inside the 12-sample rolling window for a while after
    // recording starts; span only drops below `settleSpan` once the window fully flushes back to
    // a flat baseline, and `settleCounter` then needs to exceed `settleFrames` (15) on top of that.
    // 50 trailing flat samples comfortably clears both, with margin.
    private let trailingSettleSamples = 50

    func testCleanSingleSwing() {
        var t = LiveSwingTrigger()
        for _ in 0..<6 { _ = t.step(y: 0.5, framingOK: true) }
        var actions: [LiveSwingTrigger.Action] = []
        for y in [0.5, 0.55, 0.65, 0.75, 0.55, 0.45] { actions.append(t.step(y: y, framingOK: true)) }
        XCTAssertEqual(actions.filter { $0 == .start }.count, 1, "exactly one start on a clean burst")
        for _ in 0..<trailingSettleSamples { actions.append(t.step(y: 0.5, framingOK: true)) }
        XCTAssertEqual(actions.filter { $0 == .stop }.count, 1, "exactly one stop once motion settles")
        XCTAssertFalse(t.isRecording)
    }

    func testHighVarianceNeverSettles() {
        var t = LiveSwingTrigger()
        for y in [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.55, 0.65, 0.75, 0.55, 0.45] { _ = t.step(y: y, framingOK: true) }
        XCTAssertTrue(t.isRecording, "burst should have started a recording")
        for i in 0..<100 { _ = t.step(y: 0.5 + (i % 2 == 0 ? 0.05 : -0.05), framingOK: true) }
        XCTAssertTrue(t.isRecording, "never settles ⇒ never stops without the missing-sample valve")
    }

    func testBackToBackSwings() {
        var t = LiveSwingTrigger()
        var actions: [LiveSwingTrigger.Action] = []
        func burst() { for y in [0.5, 0.55, 0.65, 0.75, 0.55, 0.45] { actions.append(t.step(y: y, framingOK: true)) } }
        func settleFlat() { for _ in 0..<trailingSettleSamples { actions.append(t.step(y: 0.5, framingOK: true)) } }
        for _ in 0..<6 { _ = t.step(y: 0.5, framingOK: true) }   // prime the window, untracked
        burst()
        settleFlat()
        burst()
        settleFlat()
        XCTAssertEqual(actions.filter { $0 == .start }.count, 2, "two independent bursts ⇒ two starts")
        XCTAssertEqual(actions.filter { $0 == .stop }.count, 2, "two independent bursts ⇒ two stops")
    }

    /// Regression test for finding #3: sustained loss of wrist tracking mid-recording (e.g. motion
    /// blur through the downswing) must not hang the recording forever.
    ///
    /// Deliberately uses a fixed frame budget (not `t.maxMissingFrames` itself, which would make
    /// this tautological — a loop bounded by the same field it's meant to be testing can never
    /// observe a regressed/too-large threshold) comfortably above the production default (45), so
    /// a future accidental widening of the ceiling still fails this test instead of silently
    /// passing because the loop grew to match.
    func testWristTrackingLostDuringSwingForcesStop() {
        var t = LiveSwingTrigger()
        for y in [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.55, 0.65, 0.75, 0.55, 0.45] { _ = t.step(y: y, framingOK: true) }
        XCTAssertTrue(t.isRecording, "burst should have started a recording")
        var stopped = false
        for _ in 0..<100 {
            if t.step(y: nil, framingOK: true) == .stop { stopped = true; break }
        }
        XCTAssertTrue(stopped, "sustained nil samples force a stop within a bounded number of frames, instead of hanging forever")
        XCTAssertFalse(t.isRecording)
    }

    func testFramingLossDoesNotStartARecording() {
        var t = LiveSwingTrigger()
        var actions: [LiveSwingTrigger.Action] = []
        for y in [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.55, 0.65, 0.75, 0.55, 0.45] {
            actions.append(t.step(y: y, framingOK: false))
        }
        XCTAssertFalse(actions.contains(.start), "a burst while out of frame must never start a recording")
        XCTAssertFalse(t.isRecording)
    }
}
