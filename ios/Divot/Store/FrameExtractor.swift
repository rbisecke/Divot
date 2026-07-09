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

    static func snapshots(videoURL: URL, session: Session, swing: SwingAnalysis,
                          ball ballIn: CGPoint? = nil) async -> [PhaseSnapshot] {
        let angle = session.angle, club = session.club, hand = session.hand
        guard let pose = try? PoseProviderFactory.make().pose(for: videoURL, fps: 30) else { return [] }
        let ref = ReferenceStore.template(category: club.category, angle: angle)
        let gen = makeGenerator(videoURL)

        let handPath = SwingLines.handPath(pose, from: swing.events.address.frame, to: swing.events.finish.frame, hand: hand)
        let headBox = SwingLines.headBox(pose, events: swing.events)

        let phases: [(Phase, SwingEvent)] = [(.address, swing.events.address), (.top, swing.events.top),
                                             (.impact, swing.events.impact), (.finish, swing.events.finish)]

        // Ball anchor: use the passed-in / persisted ball, else auto-detect on the address frame (C2).
        var ball = ballIn ?? swing.ball
        if ball == nil,
           let addrCG = try? gen.copyCGImage(at: CMTime(seconds: swing.events.address.t, preferredTimescale: 600), actualTime: nil) {
            ball = BallDetector.detectAtAddress(image: addrCG, footRegion: nil)?.point
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
}
