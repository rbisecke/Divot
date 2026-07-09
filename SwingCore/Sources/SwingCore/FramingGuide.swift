import Foundation

// P2.1 (pure slice) — is the golfer correctly framed for capture?
// Pure function over a single frame's joints so it can be validated headlessly;
// the live camera guide (device) just calls this each frame.

public enum FramingGuide {
    /// Joints that must be visible for a usable swing capture.
    public static let required: [Joint] = [
        .leftShoulder, .rightShoulder, .leftHip, .rightHip,
        .leftKnee, .rightKnee, .leftAnkle, .rightAnkle,
    ]

    /// `ok` when the whole body is in frame, centered, and a sensible size.
    /// `reason` is a short, user-facing message (also usable as the guide caption).
    public static func inFrame(_ joints: [Joint: JointPoint], margin: Double = 0.03) -> (ok: Bool, reason: String) {
        let head = joints[.nose] ?? joints[.leftEar] ?? joints[.rightEar]
        guard let head = head else { return (false, "Get your head in frame") }
        for j in required {
            guard let p = joints[j] else { return (false, "Step back — full body not visible") }
            if p.x < margin || p.x > 1 - margin || p.y < margin || p.y > 1 - margin {
                return (false, "Move to center — you're at the edge")
            }
        }
        // Vision coords are bottom-left (y up), so head sits above the ankles.
        let ankleY = min(joints[.leftAnkle]!.y, joints[.rightAnkle]!.y)
        let extent = head.y - ankleY
        if extent < 0.45 { return (false, "Step closer — you're too small in frame") }
        if extent > 0.97 { return (false, "Step back — you're too close") }
        return (true, "In frame")
    }

    /// Down-the-line guide: in frame AND side-on (facing down the target line), which
    /// shows as a small horizontal shoulder separation relative to torso height. Pure.
    public static func dtlInFrame(_ joints: [Joint: JointPoint], sideOnRatio: Double = 0.35) -> (ok: Bool, reason: String) {
        let framed = inFrame(joints)
        guard framed.ok else { return framed }
        guard let lS = joints[.leftShoulder], let rS = joints[.rightShoulder],
              let lH = joints[.leftHip], let rH = joints[.rightHip] else {
            return (false, "Step back — full body not visible")
        }
        let shoulderSep = abs(lS.x - rS.x)
        let torso = abs((lS.y + rS.y) / 2 - (lH.y + rH.y) / 2)
        guard torso > 0.01 else { return (false, "Move to center — you're at the edge") }
        if shoulderSep / torso > sideOnRatio { return (false, "Turn side-on — face down the target line") }
        return (true, "In frame (down-the-line)")
    }
}
