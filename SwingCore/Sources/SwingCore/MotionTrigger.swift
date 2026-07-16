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
    /// Safety valve: force-stop if wrist tracking drops out mid-recording (e.g. motion blur through
    /// the downswing) for this many consecutive samples, regardless of whether span ever settles.
    public var maxMissingFrames = 45

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
        if !isRecording, framingOK, span > startSpan {
            isRecording = true
            return .start
        }
        if isRecording {
            settleCounter = span < settleSpan ? settleCounter + 1 : 0
            if settleCounter > settleFrames {
                isRecording = false; settleCounter = 0
                return .stop
            }
        }
        return .none
    }
}
