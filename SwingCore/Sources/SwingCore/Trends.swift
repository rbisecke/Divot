import Foundation

// P1.5 (engine) — aggregate a metric across sessions for trend charts. Pure, UI-agnostic.

public struct TrendPoint: Sendable {
    public let date: Date
    public let value: Double
    public let swingIndex: Int
    public init(date: Date, value: Double, swingIndex: Int) {
        self.date = date; self.value = value; self.swingIndex = swingIndex
    }
}

public enum Trends {

    /// One point per session (the session's best swing), date-ordered, optionally filtered
    /// by a specific club identity (ClubSpec.id) so per-wedge trends don't fork on rename/re-loft.
    /// Best swing = the session's recorded bestSwing, else the swing with the lowest total fault severity.
    public static func series(_ sessions: [Session], metric: String, clubID: UUID? = nil) -> [TrendPoint] {
        points(sessions, metric: metric) { clubID == nil || $0.club.id == clubID }
    }

    /// Convenience: filter by analysis category (all wedges together, all irons, etc.).
    public static func series(_ sessions: [Session], metric: String, category: ClubCategory?) -> [TrendPoint] {
        points(sessions, metric: metric) { category == nil || $0.club.category == category }
    }

    private static func points(_ sessions: [Session], metric: String,
                               where include: (Session) -> Bool) -> [TrendPoint] {
        var pts: [TrendPoint] = []
        for session in sessions where include(session) {
            guard let swing = bestSwing(session) else { continue }
            guard let value = swing.metrics[metric], value.isFinite else { continue }
            pts.append(TrendPoint(date: session.date, value: value, swingIndex: swing.index))
        }
        return pts.sorted { $0.date < $1.date }
    }

    /// Trailing rolling mean over `window` points (window ≥ 1); preserves each point's date + swingIndex.
    public static func rollingMean(_ pts: [TrendPoint], window: Int) -> [TrendPoint] {
        let w = max(1, window)
        guard !pts.isEmpty else { return [] }
        var out: [TrendPoint] = []
        for i in pts.indices {
            let lo = max(0, i - w + 1)
            let slice = pts[lo...i]
            let mean = slice.reduce(0.0) { $0 + $1.value } / Double(slice.count)
            out.append(TrendPoint(date: pts[i].date, value: mean, swingIndex: pts[i].swingIndex))
        }
        return out
    }

    private static func bestSwing(_ session: Session) -> SwingAnalysis? {
        if let idx = session.stats?.bestSwing, let s = session.swings.first(where: { $0.index == idx }) { return s }
        return session.swings.min {
            $0.faults.map(\.severity).reduce(0, +) < $1.faults.map(\.severity).reduce(0, +)
        }
    }
}
