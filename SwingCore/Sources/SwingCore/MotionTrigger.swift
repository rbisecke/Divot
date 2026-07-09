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
