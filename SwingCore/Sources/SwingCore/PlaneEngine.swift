import Foundation
import CoreGraphics

// C3 — over-the-top / shallowing metric: perpendicular deviation of the downswing path
// (hand-path by default, club-head path if provided) from the shaft plane, normalized to
// shoulder width. Positive deviation on the "over" side of the plane → over-the-top.
// NOTE: the sign convention + threshold are a first pass to be tuned on real DTL footage.

public struct PlaneAnalysis: Codable, Sendable {
    public let plane: SwingLine
    public let overTheTop: Bool
    public let maxAbovePlane: Double        // shoulder-width units
    public let source: String               // "hand" | "club"
    public let downswingPath: [CGPoint]
    public init(plane: SwingLine, overTheTop: Bool, maxAbovePlane: Double, source: String, downswingPath: [CGPoint]) {
        self.plane = plane; self.overTheTop = overTheTop; self.maxAbovePlane = maxAbovePlane
        self.source = source; self.downswingPath = downswingPath
    }
}

public enum PlaneEngine {

    public static let overTheTopThreshold = 0.15   // shoulder-widths

    public static func analyze(_ pose: PoseSequence, events: SwingEvents, angle: Angle = .faceOn,
                               hand: Hand = .right, ball: CGPoint?, clubPath: [CGPoint]? = nil) -> PlaneAnalysis {
        analyze(JointSeries(pose), events: events, angle: angle, hand: hand, ball: ball, clubPath: clubPath)
    }
    /// JointSeries-accepting overload — see EventDetector.detect's overload for why. Threads the
    /// same series into SwingLines.shaftPlane/handPath too, instead of each separately rebuilding
    /// their own from the pose.
    static func analyze(_ s: JointSeries, events: SwingEvents, angle: Angle = .faceOn,
                        hand: Hand = .right, ball: CGPoint?, clubPath: [CGPoint]? = nil) -> PlaneAnalysis {
        let plane = SwingLines.shaftPlane(s, events: events, hand: hand, ball: ball)
        let path = clubPath ?? SwingLines.handPath(s, from: events.top.frame, to: events.impact.frame, hand: hand)
        let src = clubPath != nil ? "club" : "hand"

        // unit normal of the plane (top-left space)
        let dx = Double(plane.b.x - plane.a.x), dy = Double(plane.b.y - plane.a.y)
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 1e-6, !path.isEmpty else {
            return PlaneAnalysis(plane: plane, overTheTop: false, maxAbovePlane: 0, source: src, downswingPath: path)
        }
        // The fixed 90-degree rotation below assumes a right-handed swing's geometry. A lefty's
        // swing (filmed from the same camera side) is the mirror image of a righty's — joint
        // *selection* elsewhere in this file is already hand-aware, but this sign wasn't, so a
        // genuine over-the-top move for a left-handed golfer was classified as shallow and vice
        // versa (finding #7). Mirroring the normal's sign undoes exactly that reflection.
        let mirror: Double = hand == .left ? -1 : 1
        let nx = (-dy / len) * mirror, ny = (dx / len) * mirror

        // shoulder width (normalized) at address for scale
        let a = min(max(events.address.frame, 0), max(s.n - 1, 0))
        let sdx = s.jx(.leftShoulder)[a] - s.jx(.rightShoulder)[a]
        let sdy = s.jy(.leftShoulder)[a] - s.jy(.rightShoulder)[a]
        var sw = (sdx * sdx + sdy * sdy).squareRoot()
        if !(sw.isFinite && sw > 0.02) { sw = 0.2 }

        var maxDev = -Double.infinity
        for p in path {
            let dev = (Double(p.x) - Double(plane.a.x)) * nx + (Double(p.y) - Double(plane.a.y)) * ny
            if dev.isFinite { maxDev = max(maxDev, dev) }
        }
        let maxAbove = (maxDev.isFinite ? maxDev : 0) / sw
        let rounded = (maxAbove * 100).rounded() / 100
        return PlaneAnalysis(plane: plane, overTheTop: rounded > overTheTopThreshold,
                             maxAbovePlane: rounded, source: src, downswingPath: path)
    }
}
