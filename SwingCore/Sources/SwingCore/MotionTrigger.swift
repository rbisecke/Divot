import Foundation

// P2.1 (pure slice) — auto-record trigger. Given a lead-wrist speed series,
// find the swing burst and return a window with pre/post roll. Pure so it can be
// validated headlessly; the recorder feeds it live wrist speed from the pose stream.

public enum MotionTrigger {
    /// Returns the [start, end] index window bracketing the swing, or nil if no clear burst.
    /// `riseFactor` = how much the peak must exceed the mean to count as a swing.
    public static func swingWindow(leadWristSpeed speed: [Double], fps: Double,
                                   preRoll: Double = 0.5, postRoll: Double = 0.7,
                                   riseFactor: Double = 3.0) -> (startIdx: Int, endIdx: Int)? {
        let n = speed.count
        guard n >= 3, fps > 0 else { return nil }
        let sm = JointSeries.smooth(speed, 2)
        var peakIdx = 0, peakV = -Double.infinity
        for (i, v) in sm.enumerated() where v > peakV { peakV = v; peakIdx = i }
        let mean = sm.reduce(0, +) / Double(n)
        guard peakV > 1e-6, peakV > mean * riseFactor else { return nil }

        let thresh = peakV * 0.25
        var start = peakIdx
        while start > 0 && sm[start] > thresh { start -= 1 }
        var end = peakIdx
        while end < n - 1 && sm[end] > thresh { end += 1 }

        let pre = Int(preRoll * fps), post = Int(postRoll * fps)
        return (Swift.max(0, start - pre), Swift.min(n - 1, end + post))
    }
}

public extension MotionTrigger {
    /// Causal (no-lookahead) recording state for the live recorder. The caller owns
    /// `recentSpeeds` (a short trailing buffer of lead-wrist speed) and this state; `step`
    /// is a pure decision given a new sample. Mirrors `swingWindow`'s peak/mean burst test,
    /// but incremental so it can decide mid-recording instead of over a finished clip.
    struct LiveState: Equatable, Sendable {
        public var recording = false
        public var peakSpeed = 0.0        // highest speed seen since recording started
        public var stillCount = 0         // consecutive samples at/under the settle ratio
        public var samplesSinceStart = 0  // guards against stopping during a real mid-swing pause
        public init() {}
    }

    static func step(_ state: LiveState, speed: Double, recentMean: Double,
                     riseFactor: Double = 3.0, settleRatio: Double = 0.12,
                     settleSamples: Int = 15, minRecordingSamples: Int = 8) -> LiveState {
        var s = state
        if !s.recording {
            if recentMean > 1e-6, speed > recentMean * riseFactor {
                s = LiveState(); s.recording = true; s.peakSpeed = speed
            }
            return s
        }
        s.samplesSinceStart += 1
        s.peakSpeed = max(s.peakSpeed, speed)
        s.stillCount = speed < s.peakSpeed * settleRatio ? s.stillCount + 1 : 0
        if s.samplesSinceStart >= minRecordingSamples, s.stillCount > settleSamples {
            return LiveState()   // reset to idle
        }
        return s
    }
}
