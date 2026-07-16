import Foundation
import CoreGraphics

// P1.2 — coach lines derived from pose. Pure geometry, no rendering.
// Output is normalized 0…1 in TOP-LEFT screen convention (Vision is bottom-left, so y is flipped).

public struct SwingLine: Codable, Sendable {
    public let a: CGPoint, b: CGPoint
    public init(a: CGPoint, b: CGPoint) { self.a = a; self.b = b }
}

public enum SwingLines {

    /// Line keys returned by `lines(_:at:hand:)`.
    public static let keys = ["shoulder", "hip", "spine", "leadArm", "swingPlane"]

    /// Coach lines at a given frame: shoulder line, hip line, spine tilt, lead-arm/shaft, swing-plane proxy.
    /// A line is omitted if any joint it needs is missing/NaN at that frame. All points are finite and in 0…1.
    public static func lines(_ pose: PoseSequence, at frame: Int, hand: Hand = .right) -> [String: SwingLine] {
        lines(JointSeries(pose), at: frame, hand: hand)
    }
    /// JointSeries-accepting overload — see EventDetector.detect's overload for why.
    static func lines(_ s: JointSeries, at frame: Int, hand: Hand = .right) -> [String: SwingLine] {
        guard s.n > 0 else { return [:] }
        let f = min(max(frame, 0), s.n - 1)
        let lead = hand == .left ? "right" : "left"
        let trail = hand == .left ? "left" : "right"
        func J(_ side: String, _ part: String) -> Joint { Joint(rawValue: side + part)! }

        // point in top-left normalized coords, or nil if not finite
        func P(_ j: Joint) -> CGPoint? {
            let x = s.jx(j)[f], y = s.jy(j)[f]
            guard x.isFinite, y.isFinite else { return nil }
            return CGPoint(x: x, y: 1 - y)
        }
        func mid(_ p: CGPoint, _ q: CGPoint) -> CGPoint { CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2) }

        var out: [String: SwingLine] = [:]
        let ls = P(.leftShoulder), rs = P(.rightShoulder), lh = P(.leftHip), rh = P(.rightHip)
        if let ls = ls, let rs = rs { out["shoulder"] = SwingLine(a: ls, b: rs) }
        if let lh = lh, let rh = rh { out["hip"] = SwingLine(a: lh, b: rh) }
        if let ls = ls, let rs = rs, let lh = lh, let rh = rh {
            out["spine"] = SwingLine(a: mid(lh, rh), b: mid(ls, rs))
        }
        if let sh = P(J(lead, "Shoulder")), let wr = P(J(lead, "Wrist")) {
            out["leadArm"] = SwingLine(a: sh, b: wr)
        }
        // swing-plane proxy: trail shoulder through the lead hand (no club is tracked)
        if let ts = P(J(trail, "Shoulder")), let lw = P(J(lead, "Wrist")) {
            out["swingPlane"] = SwingLine(a: ts, b: lw)
        }
        return out
    }

    /// Lead-hand (wrist) path across [from, to], one point per frame, top-left normalized.
    public static func handPath(_ pose: PoseSequence, from: Int, to: Int, hand: Hand = .right) -> [CGPoint] {
        handPath(JointSeries(pose), from: from, to: to, hand: hand)
    }
    /// JointSeries-accepting overload — see EventDetector.detect's overload for why.
    static func handPath(_ s: JointSeries, from: Int, to: Int, hand: Hand = .right) -> [CGPoint] {
        guard s.n > 0 else { return [] }
        let lo = min(max(from, 0), s.n - 1), hi = min(max(to, 0), s.n - 1)
        guard hi >= lo else { return [] }
        let wr = hand.leadWrist
        let xs = s.jx(wr), ys = s.jy(wr)
        var pts: [CGPoint] = []
        for i in lo...hi where xs[i].isFinite && ys[i].isFinite {
            pts.append(CGPoint(x: xs[i], y: 1 - ys[i]))
        }
        return pts
    }

    /// Bounding box of head movement (nose, or ear-midpoint fallback) from address to finish, top-left normalized.
    public static func headBox(_ pose: PoseSequence, events: SwingEvents) -> CGRect {
        headBox(JointSeries(pose), events: events)
    }
    /// JointSeries-accepting overload — see EventDetector.detect's overload for why.
    static func headBox(_ s: JointSeries, events: SwingEvents) -> CGRect {
        guard s.n > 0 else { return .zero }
        let lo = min(max(events.address.frame, 0), s.n - 1)
        let hi = min(max(events.finish.frame, 0), s.n - 1)
        guard hi >= lo else { return .zero }
        let nx = s.jx(.nose), ny = s.jy(.nose)
        let lex = s.jx(.leftEar), ley = s.jy(.leftEar), rex = s.jx(.rightEar), rey = s.jy(.rightEar)
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        var any = false
        for i in lo...hi {
            var x = nx[i], y = ny[i]
            if !(x.isFinite && y.isFinite) {
                x = (lex[i] + rex[i]) / 2; y = (ley[i] + rey[i]) / 2
            }
            guard x.isFinite, y.isFinite else { continue }
            let sy = 1 - y
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, sy); maxY = max(maxY, sy)
            any = true
        }
        guard any else { return .zero }
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// P2.3 — total head travel (cm) from address to finish, using the same shoulder-width
    /// scale calibration as MetricsEngine (40cm shoulders face-on, 50cm torso down-the-line).
    public static func headTravelCm(_ pose: PoseSequence, events: SwingEvents,
                                    angle: Angle = .faceOn, hand: Hand = .right) -> Double {
        headTravelCm(JointSeries(pose), events: events, angle: angle, hand: hand)
    }
    /// JointSeries-accepting overload — see EventDetector.detect's overload for why.
    static func headTravelCm(_ s: JointSeries, events: SwingEvents,
                             angle: Angle = .faceOn, hand: Hand = .right) -> Double {
        let n = s.n
        guard n > 0 else { return 0 }
        let a = min(max(events.address.frame, 0), n - 1)
        func distPx(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
            let dx = (ax - bx) * s.w, dy = (ay - by) * s.h; return (dx * dx + dy * dy).squareRoot()
        }
        func midX(_ j1: Joint, _ j2: Joint, _ i: Int) -> Double { (s.jx(j1)[i] + s.jx(j2)[i]) / 2 }
        func midY(_ j1: Joint, _ j2: Joint, _ i: Int) -> Double { (s.jy(j1)[i] + s.jy(j2)[i]) / 2 }
        let shoulderWpx = distPx(s.jx(.leftShoulder)[a], s.jy(.leftShoulder)[a], s.jx(.rightShoulder)[a], s.jy(.rightShoulder)[a])
        let torsoPx = distPx(midX(.leftShoulder, .rightShoulder, a), midY(.leftShoulder, .rightShoulder, a),
                             midX(.leftHip, .rightHip, a), midY(.leftHip, .rightHip, a))
        let cmPerPx = angle == .dtl ? 50.0 / max(torsoPx, 1) : 40.0 / max(shoulderWpx, 1)
        func headX(_ i: Int) -> Double { s.jx(.nose)[i].isNaN ? midX(.leftEar, .rightEar, i) : s.jx(.nose)[i] }
        func headY(_ i: Int) -> Double { s.jy(.nose)[i].isNaN ? midY(.leftEar, .rightEar, i) : s.jy(.nose)[i] }
        let hi = min(max(events.finish.frame, 0), n - 1)
        guard hi > a else { return 0 }
        var total = 0.0
        for i in (a + 1)...hi {
            let px = distPx(headX(i), headY(i), headX(i - 1), headY(i - 1))
            if px.isFinite { total += px * cmPerPx }
        }
        return total.isFinite ? total : 0
    }
}

