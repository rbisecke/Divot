// Part of Divot (built + tested; see App/DivotApp.swift).
// P2.3/P2.4 — motion analysis that needs the pose. DEVICE-GATED (Simulator returns nil).
import Foundation
import SwingCore

extension FrameExtractor {
    struct Motion { let sequence: KinematicSequence; let headTravelCm: Double }

    static func motion(videoURL: URL, cacheURL: URL, swing: SwingAnalysis, angle: Angle, hand: Hand) async -> Motion? {
        guard let pose = await PoseCache.devicePose(videoURL: videoURL, cacheURL: cacheURL) else { return nil }
        let seq = SequenceEngine.compute(pose, events: swing.events, hand: hand)
        let head = SwingLines.headTravelCm(pose, events: swing.events, angle: angle, hand: hand)
        return Motion(sequence: seq, headTravelCm: head)
    }
}
