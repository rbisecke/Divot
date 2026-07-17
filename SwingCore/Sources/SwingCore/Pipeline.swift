import Foundation

// Top-level facade the app UI sits on. Runs the full pipeline end to end:
// pose → segment → per-swing events/metrics/faults/comparison → session stats.

public enum SwingAnalyzer {

    /// Analyze an already-extracted pose sequence (one swing).
    public static func analyze(_ pose: PoseSequence, club: ClubSpec, angle: Angle, hand: Hand = .right, index: Int = 1) throws -> SwingAnalysis {
        // A 0- or 1-frame sequence would index argmax/argmin out of range further down the
        // pipeline (finding #2) — matches the >= 5 threshold analyzeSession already applies to
        // its own per-window slices before ever reaching this function.
        guard pose.frames.count >= 5 else { throw SwingError.noSwingDetected }
        // If the tracked lead wrist is undetected across (almost) the whole clip, JointSeries has
        // no anchor to interpolate from and every downstream argmax/argmin collapses to a fixed,
        // meaningless index — a silently-wrong analysis with no error surfaced (finding #6). This
        // coverage check is independent of PoseEstimator's existing per-frame minConfidence gate,
        // which only decides whether a joint counts as detected within a single frame.
        let leadDetected = pose.frames.filter { $0.joints[hand.leadWrist] != nil }.count
        guard Double(leadDetected) / Double(pose.frames.count) >= 0.5 else { throw SwingError.lowPoseConfidence }
        // Built once and threaded through every downstream call below instead of each one
        // separately rebuilding its own from `pose` (Medium finding: "JointSeries rebuilt
        // redundantly 5-12x per swing/screen load"). Output is unchanged by construction — every
        // JointSeries-accepting overload below is the exact same code the PoseSequence-taking
        // wrapper used to run inline, just no longer recomputing the series itself.
        let series = JointSeries(pose)
        let ev = EventDetector.detect(series, hand: hand)
        let met = MetricsEngine.compute(series, events: ev, angle: angle, hand: hand)
        let faults = FaultEvaluator.evaluate(met, category: club.category, angle: angle)
        var comparison: Comparison?
        if let ref = ReferenceStore.template(category: club.category, angle: angle) {
            let userTpl = TemplateBuilder.build(pose, events: ev, category: club.category, angle: angle, metrics: met)
            comparison = PoseComparator.compare(user: userTpl, reference: ref, category: club.category, angle: angle)
        }
        var plane: PlaneAnalysis?
        if pose.frames.count >= 5 {
            plane = PlaneEngine.analyze(series, events: ev, angle: angle, hand: hand, ball: nil)
        }
        return SwingAnalysis(index: index, events: ev, metrics: met, faults: faults, comparison: comparison, plane: plane)
    }

    /// Analyze a single-swing clip.
    public static func analyze(video: URL, club: ClubSpec, angle: Angle, hand: Hand = .right, index: Int = 1,
                               provider: PoseProvider = VisionPoseProvider()) throws -> SwingAnalysis {
        try analyze(try provider.pose(for: video, fps: 30), club: club, angle: angle, hand: hand, index: index)
    }

    /// Analyze a clip that may contain several swings → a full Session with stats.
    public static func analyzeSession(video: URL, club: ClubSpec, angle: Angle, hand: Hand = .right, date: Date = Date(),
                                      provider: PoseProvider = VisionPoseProvider()) throws -> Session {
        let pose = try provider.pose(for: video, fps: 30)
        let windows = Segmenter.swings(in: pose, hand: hand)
        let subs = windows.isEmpty ? [pose] : windows.map { slice(pose, from: $0.start, to: $0.end) }
        var swings: [SwingAnalysis] = []
        for (i, sub) in subs.enumerated() where sub.frames.count >= 5 {
            // A single poorly-tracked window (e.g. lead wrist occluded for that one swing) now
            // throws lowPoseConfidence instead of silently producing garbage (finding #6) — skip
            // just that window rather than aborting the whole multi-swing session over one bad
            // swing; noSwingDetected below still covers the all-windows-bad case.
            if let a = try? analyze(sub, club: club, angle: angle, hand: hand, index: i + 1) {
                swings.append(a)
            }
        }
        if swings.isEmpty { throw SwingError.noSwingDetected }
        return Session(date: date, club: club, angle: angle, hand: hand, swings: swings, stats: SessionBuilder.stats(swings))
    }

    static func slice(_ pose: PoseSequence, from: Double, to: Double) -> PoseSequence {
        PoseSequence(fps: pose.fps, width: pose.width, height: pose.height,
                     frames: pose.frames.filter { $0.t >= from && $0.t <= to })
    }
}

// MARK: - Session stats (ported from CLI session.swift)

public enum SessionBuilder {
    static let faultInfo: [String: (label: String, cue: String, drill: String)] = {
        var m: [String: (String, String, String)] = [:]
        for d in Benchmarks.defaults { m[d.faultCode] = (d.label, d.cue, d.drill) }
        return m
    }()

    public static func stats(_ swings: [SwingAnalysis]) -> SessionStats {
        let n = swings.count
        // best swing = lowest total fault severity (most on-benchmark)
        let best = swings.min { a, b in a.faults.map(\.severity).reduce(0,+) < b.faults.map(\.severity).reduce(0,+) }
        let bestSwing = best?.index ?? swings.first?.index ?? 1
        // recurring: a fault code counted once per swing it appears in
        var counts: [String: Int] = [:]
        for s in swings { for code in Set(s.faults.map(\.code)) { counts[code, default: 0] += 1 } }
        let recurring = counts.filter { $0.value * 2 >= n }
        let focusCode = recurring.max { $0.value < $1.value }?.key
            ?? counts.max { $0.value < $1.value }?.key
        let focus: String
        if let code = focusCode, let info = faultInfo[code] {
            focus = "\(info.label) — \(info.cue) (\(info.drill))"
        } else {
            focus = "keep grooving contact"
        }
        return SessionStats(bestSwing: bestSwing, recurringFaults: counts, focus: focus)
    }
}
