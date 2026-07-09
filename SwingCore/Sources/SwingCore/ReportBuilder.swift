import Foundation

// P1.8 (engine) — deterministic Markdown summary of a session, for the Share export.

public enum ReportBuilder {

    public static func markdown(_ session: Session) -> String {
        var out = "# Swing report — \(session.club.displayName) (\(session.angle.rawValue))\n"
        let df = ISO8601DateFormatter(); df.formatOptions = [.withFullDate]
        out += "Date: \(df.string(from: session.date))\n"
        if let focus = session.stats?.focus { out += "Focus: \(focus)\n" }

        guard let swing = bestSwing(session) else {
            out += "\nNo swing detected.\n"; return out
        }
        out += "\n## Best swing (Swing \(swing.index))\n"
        if let tempo = swing.metrics.tempoRatio {
            out += String(format: "Tempo: %.1f : 1\n", tempo)
        }
        if let overall = swing.comparison?.overall {
            out += "Match to pro: \(Int((overall * 100).rounded()))%\n"
        }

        if !swing.faults.isEmpty {
            out += "\n### What to fix\n"
            for f in swing.faults {
                out += "- \(f.label) (`\(f.code)`) — \(f.cue) (Drill \(f.drill))\n"
            }
        }

        out += "\n### Measurements\n"
        for info in FaultEvaluator.benchmarks(category: session.club.category) {
            if let angles = info.angles, !angles.contains(session.angle) { continue }
            guard let v = swing.metrics[info.key] else { continue }
            let aim = info.higherIsBetter ? "≥" : "≤"
            out += String(format: "- %@: %.1f (aim %@%.1f)\n", info.label, v, aim, info.good)
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
