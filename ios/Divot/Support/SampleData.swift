// Part of Divot. DEBUG-only sample-data seeder for UI screenshots.
// Never runs in release, and only when launched with "-seedSampleData".
import Foundation
import SwiftData
import SwingCore

enum SampleData {

    static func seedIfRequested(_ context: ModelContext) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-seedSampleData") else { return }

        // Deterministic wipe so screenshots are stable across runs.
        if let existing = try? context.fetch(FetchDescriptor<SavedSession>()) {
            for s in existing { try? FileManager.default.removeItem(at: s.videoURL); context.delete(s) }
        }

        // Seed the default bag first so the sample sessions bind to real bag clubs.
        BagStore.seedDefaultBagIfEmpty(context)
        let bag = BagStore.activeBag(context)
        let pw = bag.first { $0.category == .wedge && $0.label == "PW" } ?? ClubLegacy.map(rawValue: "pw")
        let dr = bag.first { $0.category == .driver } ?? ClubLegacy.map(rawValue: "dr")
        let i7 = bag.first { $0.category == .iron && $0.number == 7 } ?? ClubLegacy.map(rawValue: "7i")

        // A run of wedge sessions (improving weight transfer + tempo over ~5 weeks) plus a
        // 7-iron and a driver, so History is populated and Trends shows a real line.
        let specs: [(club: ClubSpec, weight: Double, arm: Double, xf: Double, tempo: Double, daysAgo: Int)] = [
            (pw, 34, 26.0, 24.0, 2.4, 34),
            (pw, 47, 24.0, 28.0, 2.6, 27),
            (dr, 66, 12.0, 44.0, 3.4, 20),
            (i7, 62, 18.0, 34.0, 3.0, 13),
            (pw, 55, 22.0, 31.0, 2.9, 6),
            (pw, 41, 24.6, 27.4, 2.7, 1),   // newest = chunky wedge → faults+cues+drills list
        ]
        for spec in specs {
            let session = makeSession(spec)
            let filename = copyFixtureVideo() ?? "missing.mov"
            context.insert(SavedSession(date: session.date, club: spec.club, angle: .faceOn,
                                        hand: .right, videoFilename: filename, session: session))
        }
        try? context.save()
        #endif
    }

    #if DEBUG
    private static func makeSession(_ s: (club: ClubSpec, weight: Double, arm: Double, xf: Double, tempo: Double, daysAgo: Int)) -> Session {
        var m = SwingMetrics()
        m.tempoRatio = s.tempo
        m.weightLeadPctEst = s.weight
        m.leadArmBendDeg = s.arm
        m.xfactorDeg = s.xf
        let isWedge = s.club.category == .wedge
        m.headSwayIn = isWedge ? 3.6 : 1.9
        m.headRiseCm = isWedge ? -6.8 : -2.4
        m.pelvisSwayIn = 2.6
        m.spineLossDeg = 4.2
        m.trailKneeFlexLossDeg = 7.0

        let ev = SwingEvents(address: SwingEvent(t: 0, frame: 0), top: SwingEvent(t: 1.2, frame: 36),
                             impact: SwingEvent(t: 1.6, frame: 48), finish: SwingEvent(t: 2.2, frame: 66))
        let faults = FaultEvaluator.evaluate(m, category: s.club.category, angle: .faceOn)
        let comparison = makeComparison(events: ev, category: s.club.category, metrics: m)
        let sa = SwingAnalysis(index: 1, events: ev, metrics: m, faults: faults, comparison: comparison)
        let stats = SessionBuilder.stats([sa])
        let date = Date().addingTimeInterval(-Double(s.daysAgo) * 86_400)
        return Session(date: date, club: s.club, angle: .faceOn, hand: .right, swings: [sa], stats: stats)
    }

    /// Real comparison: build a normalized template from a synthetic pose (no Vision needed)
    /// and compare it to the bundled pro reference.
    private static func makeComparison(events: SwingEvents, category: ClubCategory, metrics: SwingMetrics) -> Comparison? {
        guard let ref = ReferenceStore.template(category: category, angle: .faceOn) else { return nil }
        let n = events.finish.frame + 1
        var frames: [PoseFrame] = []
        for i in 0..<n { frames.append(PoseFrame(t: Double(i) / 30.0, joints: pose(phase: Double(i) / Double(max(n - 1, 1))))) }
        let seq = PoseSequence(fps: 30, width: 1080, height: 1920, frames: frames)
        let user = TemplateBuilder.build(seq, events: events, category: category, angle: .faceOn, metrics: metrics)
        return PoseComparator.compare(user: user, reference: ref, category: category, angle: .faceOn)
    }

    /// A plausible face-on golfer pose (Vision normalized, bottom-left origin) whose arms swing
    /// with `phase` (0=address … 1=finish), so per-phase match varies.
    private static func pose(phase p: Double) -> [Joint: JointPoint] {
        func jp(_ x: Double, _ y: Double) -> JointPoint { JointPoint(x: x, y: y, c: 0.9) }
        let swing = sin(p * .pi)                 // arms rise then fall
        let wristY = 0.50 + 0.28 * swing
        let wristX = 0.02 * cos(p * .pi)
        return [
            .nose: jp(0.50, 0.86), .neck: jp(0.50, 0.78),
            .leftShoulder: jp(0.43, 0.74), .rightShoulder: jp(0.57, 0.74),
            .leftElbow: jp(0.41, 0.62), .rightElbow: jp(0.59, 0.62),
            .leftWrist: jp(0.47 + wristX, wristY), .rightWrist: jp(0.53 + wristX, wristY),
            .leftHip: jp(0.46, 0.50), .rightHip: jp(0.54, 0.50),
            .leftKnee: jp(0.45, 0.30), .rightKnee: jp(0.55, 0.30),
            .leftAnkle: jp(0.45, 0.10), .rightAnkle: jp(0.55, 0.10),
        ]
    }

    /// Copy the bundled sample clip into Documents so the sequence strip / player have a real file.
    private static func copyFixtureVideo() -> String? {
        guard let src = Bundle.main.url(forResource: "placeholder_swing", withExtension: "mov") else { return nil }
        let filename = "\(UUID().uuidString).mov"
        let dest = AppPaths.videosDir.appendingPathComponent(filename)
        do { try FileManager.default.copyItem(at: src, to: dest); return filename }
        catch { return nil }
    }
    #endif
}
