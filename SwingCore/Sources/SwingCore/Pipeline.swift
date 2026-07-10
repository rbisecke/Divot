import Foundation
import AVFoundation
import CoreGraphics

// Top-level facade the app UI sits on. Runs the full pipeline end to end:
// pose → segment → per-swing events/metrics/faults/comparison → session stats.

public enum SwingAnalyzer {

    /// Analyze an already-extracted pose sequence (one swing). `videoURL`, when supplied,
    /// enables the P3.5 ball-contact soft-label signal (best-effort; nil when omitted, same
    /// as `plane`/`comparison`).
    public static func analyze(_ pose: PoseSequence, club: ClubSpec, angle: Angle, hand: Hand = .right, index: Int = 1,
                               videoURL: URL? = nil) -> SwingAnalysis {
        let ev = EventDetector.detect(pose, hand: hand)
        let met = MetricsEngine.compute(pose, events: ev, angle: angle, hand: hand)
        let faults = FaultEvaluator.evaluate(met, category: club.category, angle: angle)
        var comparison: Comparison?
        if let ref = ReferenceStore.template(category: club.category, angle: angle) {
            let userTpl = TemplateBuilder.build(pose, events: ev, category: club.category, angle: angle, metrics: met)
            comparison = PoseComparator.compare(user: userTpl, reference: ref, category: club.category, angle: angle)
        }
        var plane: PlaneAnalysis?
        if pose.frames.count >= 5 {
            plane = PlaneEngine.analyze(pose, events: ev, angle: angle, hand: hand, ball: nil)
        }
        var contact: ContactSignal?
        if let videoURL = videoURL {
            contact = evaluateContact(videoURL: videoURL, events: ev)
        }
        return SwingAnalysis(index: index, events: ev, metrics: met, faults: faults, comparison: comparison,
                             plane: plane, contact: contact)
    }

    /// Analyze a single-swing clip.
    public static func analyze(video: URL, club: ClubSpec, angle: Angle, hand: Hand = .right, index: Int = 1,
                               provider: PoseProvider = VisionPoseProvider()) throws -> SwingAnalysis {
        analyze(try provider.pose(for: video, fps: 30), club: club, angle: angle, hand: hand, index: index, videoURL: video)
    }

    /// Analyze a clip that may contain several swings → a full Session with stats.
    public static func analyzeSession(video: URL, club: ClubSpec, angle: Angle, hand: Hand = .right, date: Date = Date(),
                                      provider: PoseProvider = VisionPoseProvider()) throws -> Session {
        let pose = try provider.pose(for: video, fps: 30)
        let windows = Segmenter.swings(in: pose, hand: hand)
        let subs = windows.isEmpty ? [pose] : windows.map { slice(pose, from: $0.start, to: $0.end) }
        var swings: [SwingAnalysis] = []
        for (i, sub) in subs.enumerated() where sub.frames.count >= 5 {
            swings.append(analyze(sub, club: club, angle: angle, hand: hand, index: i + 1, videoURL: video))
        }
        if swings.isEmpty { throw SwingError.noSwingDetected }
        return Session(date: date, club: club, angle: angle, hand: hand, swings: swings, stats: SessionBuilder.stats(swings))
    }

    static func slice(_ pose: PoseSequence, from: Double, to: Double) -> PoseSequence {
        PoseSequence(fps: pose.fps, width: pose.width, height: pose.height,
                     frames: pose.frames.filter { $0.t >= from && $0.t <= to })
    }

    /// P3.5 glue: pulls the address + a post-impact still from `videoURL` and runs the
    /// already-existing `BallDetector`/`BallFlightTracer` best-effort passes, then hands the
    /// results to the pure `ContactEvaluator`. Device-gated like its inputs; degrades to
    /// "not evaluated" (not a crash) when a frame or ball can't be read.
    private static func evaluateContact(videoURL: URL, events: SwingEvents) -> ContactSignal {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.01, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.01, preferredTimescale: 600)

        let ballAtAddress = (try? gen.copyCGImage(at: CMTime(seconds: events.address.t, preferredTimescale: 600), actualTime: nil))
            .flatMap { BallDetector.detectAtAddress(image: $0)?.point }

        let flight = BallFlightTracer.trace(videoURL: videoURL)

        var ballStillAtAddressSpot = false
        if let anchor = ballAtAddress,
           let postCG = try? gen.copyCGImage(at: CMTime(seconds: events.finish.t, preferredTimescale: 600), actualTime: nil),
           let postBall = BallDetector.detectAtAddress(image: postCG)?.point {
            let dx = postBall.x - anchor.x, dy = postBall.y - anchor.y
            ballStillAtAddressSpot = (dx * dx + dy * dy).squareRoot() < 0.03   // small radius, normalized coords
        }

        return ContactEvaluator.evaluate(ballAtAddress: ballAtAddress, flightDetected: flight.detected,
                                         ballStillAtAddressSpot: ballStillAtAddressSpot)
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
