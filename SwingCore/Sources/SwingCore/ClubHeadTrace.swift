import Foundation
import CoreGraphics

// C5 — automatic club-head trace. The DETECTOR is a documented spike (a real Core ML model
// needs a labeled dataset). Here: the protocol, a placeholder detector, and a PURE tracker
// that links per-frame detections into a smoothed, gap-interpolated arc.

public struct ClubPoint: Codable, Sendable {
    public let t: Double
    public let pos: CGPoint
    public let conf: Double
    public init(t: Double, pos: CGPoint, conf: Double) { self.t = t; self.pos = pos; self.conf = conf }
}

public struct ClubHeadPath: Codable, Sendable {
    public let points: [ClubPoint]
    public let coverage: Double        // fraction of frames with a real detection (0…1)
    public init(points: [ClubPoint], coverage: Double) { self.points = points; self.coverage = coverage }
}

/// Per-frame club-head detector. `priorNear` is the last known position (a search hint).
public protocol ClubHeadDetector: Sendable {
    func detect(_ image: CGImage, priorNear: CGPoint?) -> (CGPoint, Double)?
}

/// Placeholder — no trained model yet. Returns nil (honest). A real Core ML detector is a
/// separate spike (see EXPERIMENTAL.md / the design doc), gated by an on-device accuracy bar.
public struct HeuristicClubHeadDetector: ClubHeadDetector {
    public init() {}
    public func detect(_ image: CGImage, priorNear: CGPoint?) -> (CGPoint, Double)? { nil }
}

public enum ClubTracker {
    /// Link per-frame detections (some may be nil) into a smoothed, gap-interpolated club-head path.
    /// `wristPath` (grip locations, per frame if available) is used only to keep points plausible.
    public static func path(detections: [(t: Double, pt: CGPoint?, conf: Double)],
                            wristPath: [CGPoint] = []) -> ClubHeadPath {
        let n = detections.count
        guard n > 0 else { return ClubHeadPath(points: [], coverage: 0) }
        let present = detections.reduce(0) { $0 + ($1.pt != nil ? 1 : 0) }

        var xs: [Double?] = detections.map { $0.pt.map { Double($0.x) } }
        var ys: [Double?] = detections.map { $0.pt.map { Double($0.y) } }
        interpolate(&xs); interpolate(&ys)
        let sx = smooth(xs), sy = smooth(ys)

        var pts: [ClubPoint] = []
        for i in 0..<n {
            guard let x = sx[i], let y = sy[i], x.isFinite, y.isFinite else { continue }
            pts.append(ClubPoint(t: detections[i].t, pos: CGPoint(x: x, y: y), conf: detections[i].conf))
        }
        let coverage = (Double(present) / Double(n) * 100).rounded() / 100
        return ClubHeadPath(points: pts, coverage: coverage)
    }

    // Fill nil gaps by linear interpolation between nearest present neighbors; extend the ends.
    private static func interpolate(_ a: inout [Double?]) {
        let n = a.count
        var last = -1
        for i in 0..<n where a[i] != nil {
            if last >= 0 && i - last > 1 {
                let v0 = a[last]!, v1 = a[i]!
                for k in (last + 1)..<i {
                    let f = Double(k - last) / Double(i - last)
                    a[k] = v0 * (1 - f) + v1 * f
                }
            }
            last = i
        }
        if let first = a.firstIndex(where: { $0 != nil }) { for k in 0..<first { a[k] = a[first]! } }
        if let lastP = a.lastIndex(where: { $0 != nil }) { for k in (lastP + 1)..<n where n > 0 { a[k] = a[lastP]! } }
    }

    private static func smooth(_ a: [Double?]) -> [Double?] {
        let n = a.count
        var out = a
        for i in 0..<n {
            let lo = max(0, i - 1), hi = min(n - 1, i + 1)
            var s = 0.0, c = 0.0
            for k in lo...hi { if let v = a[k], v.isFinite { s += v; c += 1 } }
            out[i] = c > 0 ? s / c : a[i]
        }
        return out
    }
}
