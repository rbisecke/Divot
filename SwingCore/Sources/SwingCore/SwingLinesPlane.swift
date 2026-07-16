import Foundation
import CoreGraphics

// C1 — target line + shaft/swing plane anchored at the ball. Pure geometry, top-left normalized.

public extension SwingLines {

    /// Dashed target line through the ball, spanning the frame width at the ball's height.
    /// (In both views the target line reads as horizontal across the ball.)
    static func targetLine(ball: CGPoint, angle: Angle = .faceOn) -> SwingLine {
        let y = ball.y.isFinite ? ball.y : 0.85
        return SwingLine(a: CGPoint(x: 0, y: y), b: CGPoint(x: 1, y: y))
    }

    /// Shaft / swing-plane line anchored at the ball, angled along the address shaft
    /// (lead-wrist grip → ball), extended slightly past both ends for drawing.
    /// Falls back to the lead-arm line when the ball isn't known.
    static func shaftPlane(_ pose: PoseSequence, events: SwingEvents, hand: Hand = .right, ball: CGPoint?) -> SwingLine {
        shaftPlane(JointSeries(pose), events: events, hand: hand, ball: ball)
    }
    /// JointSeries-accepting overload — see EventDetector.detect's overload for why.
    internal static func shaftPlane(_ s: JointSeries, events: SwingEvents, hand: Hand = .right, ball: CGPoint?) -> SwingLine {
        let leadArm = SwingLines.lines(s, at: events.address.frame, hand: hand)["leadArm"]
        let grip = leadArm?.b  // leadArm = shoulder(a) → wrist(b)
        guard let ball = ball, ball.x.isFinite, ball.y.isFinite, let grip = grip else {
            return leadArm ?? SwingLine(a: CGPoint(x: 0.5, y: 0.4), b: CGPoint(x: 0.5, y: 0.9))
        }
        var dx = Double(ball.x - grip.x), dy = Double(ball.y - grip.y)
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 1e-6 else { return SwingLine(a: grip, b: ball) }
        dx /= len; dy /= len
        let a = CGPoint(x: Double(grip.x) - dx * 0.18, y: Double(grip.y) - dy * 0.18)
        let b = CGPoint(x: Double(ball.x) + dx * 0.18, y: Double(ball.y) + dy * 0.18)
        return SwingLine(a: a, b: b)
    }
}
