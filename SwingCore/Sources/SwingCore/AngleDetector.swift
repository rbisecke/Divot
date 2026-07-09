import Foundation

// P1.6 — classify camera angle (face-on vs down-the-line) from the setup pose.
// Face-on: shoulders are wide (perpendicular to camera) → high shoulderWidth/torsoHeight.
// Down-the-line: golfer is side-on, shoulders project narrow → low ratio.

public enum AngleDetector {

    /// Ratio boundary between the two views (tuned against the face-on fixture; DTL fixture pending).
    static let threshold = 0.55

    public static func detect(_ pose: PoseSequence, events: SwingEvents) -> (angle: Angle, confidence: Double) {
        let s = JointSeries(pose)
        guard s.n > 0 else { return (.faceOn, 0) }
        let f = min(max(events.address.frame, 0), s.n - 1)

        func px(_ j1: Joint, _ j2: Joint) -> Double? {
            let ax = s.jx(j1)[f], ay = s.jy(j1)[f], bx = s.jx(j2)[f], by = s.jy(j2)[f]
            guard ax.isFinite, ay.isFinite, bx.isFinite, by.isFinite else { return nil }
            let dx = (ax - bx) * s.w, dy = (ay - by) * s.h
            return (dx * dx + dy * dy).squareRoot()
        }
        func mid(_ j1: Joint, _ j2: Joint) -> (Double, Double)? {
            let ax = s.jx(j1)[f], ay = s.jy(j1)[f], bx = s.jx(j2)[f], by = s.jy(j2)[f]
            guard ax.isFinite, ay.isFinite, bx.isFinite, by.isFinite else { return nil }
            return ((ax + bx) / 2, (ay + by) / 2)
        }

        guard let shoulderW = px(.leftShoulder, .rightShoulder),
              let sMid = mid(.leftShoulder, .rightShoulder),
              let hMid = mid(.leftHip, .rightHip) else { return (.faceOn, 0) }
        let dx = (sMid.0 - hMid.0) * s.w, dy = (sMid.1 - hMid.1) * s.h
        let torsoH = (dx * dx + dy * dy).squareRoot()
        guard torsoH > 1 else { return (.faceOn, 0) }

        let ratio = shoulderW / torsoH
        let angle: Angle = ratio >= threshold ? .faceOn : .dtl
        // confidence scales with distance from the threshold, capped at 1.
        let confidence = min(1.0, abs(ratio - threshold) / threshold)
        return (angle, confidence)
    }
}
