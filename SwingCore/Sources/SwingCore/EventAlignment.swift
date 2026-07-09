import Foundation

// P2.2 (pure slice) — time-warp for side-by-side of two swings.
// Maps a time in swing A onto the corresponding time in swing B by piecewise-linear
// interpolation across the shared events (address → top → impact → finish).

public enum EventAlignment {
    public static func mapTime(_ t: Double, from a: SwingEvents, to b: SwingEvents) -> Double {
        let ax = [a.address.t, a.top.t, a.impact.t, a.finish.t]
        let bx = [b.address.t, b.top.t, b.impact.t, b.finish.t]
        if t <= ax[0] { return bx[0] }
        if t >= ax[3] { return bx[3] }
        for k in 0..<3 where t >= ax[k] && t <= ax[k + 1] {
            let denom = ax[k + 1] - ax[k]
            let f = denom > 0 ? (t - ax[k]) / denom : 0
            return bx[k] + (bx[k + 1] - bx[k]) * f
        }
        return bx[3]
    }
}
