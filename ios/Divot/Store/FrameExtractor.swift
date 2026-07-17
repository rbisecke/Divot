// Part of Divot (built + tested; see App/DivotApp.swift).
import AVFoundation
import UIKit
import SwingCore

/// Pulls still frames, pose overlays, and coach lines for the review/ghost screens.
/// Recomputes pose once from the stored clip (short, ~1s on device) rather than persisting it.
enum FrameExtractor {

    /// A single phase snapshot: the video still + user's raw pose + the pro ghost + coach lines,
    /// all in top-left screen-normalized coords (x right, y down) ready to draw over the image.
    struct PhaseSnapshot: Identifiable {
        let id = UUID()
        let phase: Phase
        let image: UIImage
        let userPoints: [Joint: CGPoint]
        let ghostPoints: [Joint: CGPoint]
        let lines: [String: SwingLine]     // P1.2 coach lines at this phase
        let handPath: [CGPoint]            // lead-hand path across the swing
        let headBox: CGRect                // head-movement box
        // Club-path additions (top-left normalized). Optional/empty when unavailable.
        var ball: CGPoint? = nil           // address ball anchor
        var targetLine: SwingLine? = nil   // dashed target line through the ball
        var shaftPlane: SwingLine? = nil   // ball-anchored shaft plane
        var clubHeadPath: [CGPoint] = []   // experimental club-head arc
        var ballFlight: [CGPoint] = []     // post-impact ball flight
    }

    /// P1.4 — one still per event, no pose (works on the Simulator; no Vision).
    struct Still: Identifiable { let id = UUID(); let phase: Phase; let image: UIImage }

    static func eventTimes(_ events: SwingEvents) -> [(phase: Phase, t: Double)] {
        [(.address, events.address.t), (.top, events.top.t), (.impact, events.impact.t), (.finish, events.finish.t)]
    }

    private static func makeGenerator(_ url: URL) -> AVAssetImageGenerator {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.01, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.01, preferredTimescale: 600)
        return gen
    }

    static func stills(videoURL: URL, events: SwingEvents) async -> [Still] {
        let gen = makeGenerator(videoURL)
        var out: [Still] = []
        for (phase, t) in eventTimes(events) {
            if let cg = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) {
                out.append(Still(phase: phase, image: UIImage(cgImage: cg)))
            }
        }
        return out
    }

    static func snapshots(videoURL: URL, cacheURL: URL, session: Session, swing: SwingAnalysis,
                          ball ballIn: CGPoint? = nil) async -> [PhaseSnapshot] {
        let angle = session.angle, club = session.club, hand = session.hand
        guard let pose = await PoseCache.pose(videoURL: videoURL, cacheURL: cacheURL, fps: 30) else { return [] }
        let ref = ReferenceStore.template(category: club.category, angle: angle)
        let gen = makeGenerator(videoURL)

        let handPath = SwingLines.handPath(pose, from: swing.events.address.frame, to: swing.events.finish.frame, hand: hand)
        let headBox = SwingLines.headBox(pose, events: swing.events)

        let phases: [(Phase, SwingEvent)] = [(.address, swing.events.address), (.top, swing.events.top),
                                             (.impact, swing.events.impact), (.finish, swing.events.finish)]

        // Ball anchor: use the passed-in / persisted ball, else auto-detect on the address frame (C2).
        // Derives a real search region from the address-frame ankles instead of always scanning
        // the full-resolution frame (Medium finding: ~33MB transient allocation on a 4K frame,
        // repeated on every load and re-anchor tap).
        var ball = ballIn ?? swing.ball
        if ball == nil,
           let addrCG = try? gen.copyCGImage(at: CMTime(seconds: swing.events.address.t, preferredTimescale: 600), actualTime: nil) {
            let addressFrame = nearestFrame(pose, t: swing.events.address.t)
            ball = BallDetector.detectAtAddress(image: addrCG, footRegion: ballSearchRegion(addressFrame))?.point
        }
        let targetLine = ball.map { SwingLines.targetLine(ball: $0, angle: angle) }
        let shaftPlane = SwingLines.shaftPlane(pose, events: swing.events, hand: hand, ball: ball)
        let clubHeadPath = swing.clubHeadPath?.points.map { CGPoint(x: $0.pos.x, y: $0.pos.y) } ?? []
        let ballFlight = swing.ballFlight?.points ?? []

        var out: [PhaseSnapshot] = []
        for (phase, ev) in phases {
            guard let cg = try? gen.copyCGImage(at: CMTime(seconds: ev.t, preferredTimescale: 600), actualTime: nil) else { continue }
            let img = UIImage(cgImage: cg)
            let frame = nearestFrame(pose, t: ev.t)

            // user skeleton — Vision coords are bottom-left origin; flip Y for screen.
            var user: [Joint: CGPoint] = [:]
            for (j, p) in frame.joints { user[j] = CGPoint(x: p.x, y: 1 - p.y) }

            // pro ghost — place the normalized template on the user's body, then flip Y.
            var ghost: [Joint: CGPoint] = [:]
            if let ref = ref, let refPhase = ref.phases[phase],
               let lh = frame.joints[.leftHip], let rh = frame.joints[.rightHip],
               let ls = frame.joints[.leftShoulder], let rs = frame.joints[.rightShoulder] {
                let ox = (lh.x + rh.x) / 2, oy = (lh.y + rh.y) / 2
                let sw = max(0.02, (((ls.x - rs.x) * (ls.x - rs.x) + (ls.y - rs.y) * (ls.y - rs.y)).squareRoot()))
                for (j, mp) in refPhase { ghost[j] = CGPoint(x: ox + mp.x * sw, y: 1 - (oy + mp.y * sw)) }
            }

            let lines = SwingLines.lines(pose, at: ev.frame, hand: hand)
            out.append(PhaseSnapshot(phase: phase, image: img, userPoints: user, ghostPoints: ghost,
                                     lines: lines, handPath: handPath, headBox: headBox,
                                     ball: ball, targetLine: targetLine, shaftPlane: shaftPlane,
                                     clubHeadPath: clubHeadPath, ballFlight: ballFlight))
        }
        return out
    }

    private static func nearestFrame(_ pose: PoseSequence, t: Double) -> PoseFrame {
        var best = pose.frames.first ?? PoseFrame(t: 0, joints: [:])
        var bv = Double.infinity
        for f in pose.frames { let d = abs(f.t - t); if d < bv { bv = d; best = f } }
        return best
    }

    /// A search region around the golfer's feet, derived from the address-frame ankles, so
    /// BallDetector.detectAtAddress only needs to scan (and crop to) that area instead of the
    /// full-resolution frame. Non-private so it's independently testable. Returns nil when no
    /// ankle was detected that frame (BallDetector then falls back to a full-frame scan).
    static func ballSearchRegion(_ frame: PoseFrame) -> CGRect? {
        let ankles = [frame.joints[.leftAnkle], frame.joints[.rightAnkle]].compactMap { $0 }
        guard !ankles.isEmpty else { return nil }
        let midX = ankles.map(\.x).reduce(0, +) / Double(ankles.count)
        let footY = ankles.map { 1 - $0.y }.max() ?? 0.9   // Vision is bottom-left; flip to top-left
        let x0 = max(0, midX - 0.3), x1 = min(1, midX + 0.3)
        let y0 = max(0, footY - 0.05), y1 = min(1, footY + 0.25)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
