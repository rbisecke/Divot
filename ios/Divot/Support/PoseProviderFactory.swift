// Part of Divot (built + tested; see App/DivotApp.swift).
import Foundation
import SwingCore

/// Chooses how pose is obtained. On a real device (and macOS) we run Apple Vision.
/// On the iOS Simulator there is no Neural Engine, so `VNDetectHumanBodyPoseRequest`
/// returns nothing — there we replay a pose recorded from real Vision (bundled as
/// sample_swing.pose.json) so the whole pipeline still runs end to end.
enum PoseProviderFactory {
    static func make() -> PoseProvider {
        #if targetEnvironment(simulator)
        if let url = Bundle.main.url(forResource: "sample_swing.pose", withExtension: "json"),
           let replay = try? ReplayPoseProvider(contentsOf: url) {
            return replay
        }
        return VisionPoseProvider()   // fallback (will produce empty pose on Simulator)
        #else
        return VisionPoseProvider()
        #endif
    }

    /// True when analysis is running on recorded pose rather than live Vision, so the UI
    /// can show an honest "Simulator: replayed pose" note.
    static var isReplaying: Bool {
        #if targetEnvironment(simulator)
        return Bundle.main.url(forResource: "sample_swing.pose", withExtension: "json") != nil
        #else
        return false
        #endif
    }
}
