import Foundation

// P2.11 — incremental (causal, no-lookahead) swing-phase classification for the live
// recorder. Mirrors EventDetector's address/top/impact/finish vocabulary but decided
// frame-by-frame from a trailing window only, since a live UI can't wait for the whole clip.

public enum SwingPhase: String, Sendable, CaseIterable {
    case address, backswing, transition, downswing, impact, finish
}

public enum LivePhaseDetector {
    public struct State: Equatable, Sendable {
        public var phase: SwingPhase = .address
        // EMA-smoothed speed/wristY (nil wristY = "no prior sample", i.e. the first frame of a
        // fresh recording). Real Vision pose data has real single-frame noise (a misdetected
        // joint can spike speed 10x or move wristY the wrong way for exactly one frame), and a
        // per-frame sign/threshold test on raw values fires on that noise, not on the swing.
        public var smoothedSpeed: Double = 0
        public var smoothedWristY: Double?
        public var peakSpeedSoFar: Double = 0   // rescoped at each phase boundary below
        public var risingRun: Int = 0           // consecutive smoothed-dy<0 samples (backswing→transition)
        public var fallingRun: Int = 0          // consecutive off-peak samples (downswing→impact)
        public init() {}
    }

    /// One causal step. `speed`/`wristY` come from the same sampled pose frame the P2.9
    /// trigger already reads; `trigger` is `MotionTrigger.LiveState` from the same call site
    /// (shared buffer, not recomputed) so "is recording" and "which phase" never disagree.
    ///
    /// Deviates from the original design sketch in two ways, both found while cross-checking
    /// against the real `sample_swing.pose.json` fixture (see `AppValidationTests
    /// .testLivePhaseDetectorMatchesEventDetectorOnRealPose`), not just synthetic arrays:
    ///
    /// 1. The sketch's `.downswing` test updated `peakSpeedSoFar` with `max(peakSpeedSoFar,
    ///    speed)` *before* comparing `speed >= peakSpeedSoFar` — the just-updated peak always
    ///    equals the current speed while still climbing, so that comparison is true on every
    ///    accelerating frame and false again the instant it isn't, which is backwards. Here the
    ///    peak is compared *before* being updated, so "off the peak" fires once speed drops
    ///    below it, and the peak itself is rescoped to start fresh at the downswing boundary so
    ///    a faster backswing/transition sample can't leave a stale high-water mark that trips
    ///    the test before the downswing even accelerates.
    /// 2. The sketch's raw per-frame `speed`/`wristY` sign tests are viable on the clean
    ///    synthetic arrays in `SwingCoreCheck` but fire almost immediately on the real fixture
    ///    (frame ~15 of ~125, versus the golden impact at frame 56) because real Vision output
    ///    has single-frame spikes and reversals that are pure noise, not swing motion. Both
    ///    inputs are EMA-smoothed here, and both the backswing→transition and downswing→impact
    ///    transitions require a short run of consecutive supporting samples (not one), which
    ///    brings the real-fixture cross-check to within a few frames of `EventDetector`'s
    ///    non-causal impact frame while leaving the synthetic T1 checks (already smooth,
    ///    unaffected by camera noise) unchanged.
    public static func step(_ state: State, speed: Double, wristY: Double,
                            trigger: MotionTrigger.LiveState,
                            speedSmoothing: Double = 0.5, wristSmoothing: Double = 0.5,
                            risingSamplesNeeded: Int = 2, fallingSamplesNeeded: Int = 3,
                            transitionSpeedFrac: Double = 0.3, impactDropRatio: Double = 0.8) -> State {
        var s = state
        guard trigger.recording else { return State() }   // idle whenever not recording

        s.smoothedSpeed = s.smoothedWristY == nil ? speed : s.smoothedSpeed * speedSmoothing + speed * (1 - speedSmoothing)
        let dy: Double
        if let lastY = s.smoothedWristY {
            let newY = lastY * wristSmoothing + wristY * (1 - wristSmoothing)
            dy = newY - lastY
            s.smoothedWristY = newY
        } else {
            s.smoothedWristY = wristY
            dy = 0
        }

        switch s.phase {
        case .address:
            s.phase = .backswing
            s.peakSpeedSoFar = s.smoothedSpeed
        case .backswing:
            s.peakSpeedSoFar = max(s.peakSpeedSoFar, s.smoothedSpeed)
            s.risingRun = dy < 0 ? s.risingRun + 1 : 0
            if s.risingRun >= risingSamplesNeeded {   // wristY stopped rising, and it stuck
                s.phase = .transition
                s.risingRun = 0
            }
        case .transition:
            if dy < 0, s.smoothedSpeed > s.peakSpeedSoFar * transitionSpeedFrac {
                s.phase = .downswing
                s.peakSpeedSoFar = s.smoothedSpeed   // rescope: track the peak within downswing only
                s.fallingRun = 0
            }
        case .downswing:
            if s.smoothedSpeed >= s.peakSpeedSoFar {
                s.peakSpeedSoFar = s.smoothedSpeed   // still accelerating toward impact
                s.fallingRun = 0
            } else if s.smoothedSpeed < s.peakSpeedSoFar * impactDropRatio {
                s.fallingRun += 1
                if s.fallingRun >= fallingSamplesNeeded { s.phase = .impact }   // impact just passed
            } else {
                s.fallingRun = 0
            }
        case .impact:
            if trigger.stillCount > 3 { s.phase = .finish }
        case .finish:
            break   // terminal until the next recording starts (state resets to .address)
        }
        return s
    }
}
