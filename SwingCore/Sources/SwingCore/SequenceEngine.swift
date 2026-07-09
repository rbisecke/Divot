import Foundation

// P2.4 — 2D kinematic sequence. Timing of peak angular speed for pelvis → torso →
// lead arm → hands. A good swing fires proximal-to-distal. 2D projection estimate
// (single camera), labelled as such in the UI.

public struct KinematicSequence: Sendable {
    public let order: [String]                 // segment names, earliest peak first
    public let peakTimes: [String: Double]     // seconds
    public let inSequence: Bool                // true if pelvis→torso→arm→hand non-decreasing
    public init(order: [String], peakTimes: [String: Double], inSequence: Bool) {
        self.order = order; self.peakTimes = peakTimes; self.inSequence = inSequence
    }
}

public enum SequenceEngine {
    /// Proximal-to-distal segment order used for the in-sequence test.
    public static let segments = ["pelvis", "torso", "arm", "hand"]

    public static func compute(_ pose: PoseSequence, events: SwingEvents, hand: Hand = .right) -> KinematicSequence {
        let s = JointSeries(pose); let n = s.n
        guard n >= 3 else { return KinematicSequence(order: [], peakTimes: [:], inSequence: false) }
        let lead = hand == .left ? "right" : "left"
        func J(_ side: String, _ part: String) -> Joint { Joint(rawValue: side + part)! }

        func lineAngle(_ j1: Joint, _ j2: Joint, _ i: Int) -> Double {
            let dx = (s.jx(j2)[i] - s.jx(j1)[i]) * s.w
            let dy = (s.jy(j2)[i] - s.jy(j1)[i]) * s.h
            return atan2(dy, dx)
        }
        func angSpeed(_ j1: Joint, _ j2: Joint) -> [Double] {
            var out = [Double](repeating: 0, count: n)
            var prev = lineAngle(j1, j2, 0)
            for i in 1..<n {
                let cur = lineAngle(j1, j2, i)
                var d = cur - prev
                while d > .pi { d -= 2 * .pi }
                while d < -.pi { d += 2 * .pi }
                out[i] = abs(d)
                prev = cur
            }
            return JointSeries.smooth(out, 2)
        }
        let segJoints: [(String, Joint, Joint)] = [
            ("pelvis", .leftHip, .rightHip),
            ("torso", .leftShoulder, .rightShoulder),
            ("arm", J(lead, "Shoulder"), J(lead, "Elbow")),
            ("hand", J(lead, "Elbow"), J(lead, "Wrist")),
        ]
        // Search from top through a little past impact (where the sequence fires).
        let lo = min(max(events.top.frame, 0), n - 1)
        let hiRaw = events.impact.frame + Int(0.1 * (pose.fps > 0 ? pose.fps : 30))
        let hi = min(max(hiRaw, lo + 1), n - 1)

        var peakTimes: [String: Double] = [:]
        for (name, j1, j2) in segJoints {
            let sp = angSpeed(j1, j2)
            var bi = lo, bv = -Double.infinity
            for i in lo...hi where sp[i] > bv { bv = sp[i]; bi = i }
            peakTimes[name] = s.times[bi]
        }
        let order = segments.sorted { (peakTimes[$0] ?? 0) < (peakTimes[$1] ?? 0) }
        var inSeq = true
        for k in 0..<(segments.count - 1) where (peakTimes[segments[k]] ?? 0) > (peakTimes[segments[k + 1]] ?? 0) + 1e-9 {
            inSeq = false; break
        }
        return KinematicSequence(order: order, peakTimes: peakTimes, inSequence: inSeq)
    }
}
