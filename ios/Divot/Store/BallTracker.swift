// Part of Divot (built + tested; see App/DivotApp.swift).
// ⚠️ EXPERIMENTAL, DEVICE-ONLY, HIGH RISK. Requires a stationary (tripod) camera.
// See EXPERIMENTAL.md for the on-device spike bar before this is enabled.
import Foundation
import Vision
import CoreMedia

/// P3.3 — ball-flight tracking via VNDetectTrajectoriesRequest (parabolic, stationary camera).
/// Club-head tracking is intentionally NOT implemented: the club head moves on an arc, not a
/// parabola, so it needs a custom Create ML object detector + a device spike (not shipping).
enum BallTracker {
    /// Build a configured trajectories request. The caller feeds sequential frames through a
    /// VNSequenceRequestHandler on device; the completion delivers detected trajectories.
    static func makeRequest(trajectoryLength: Int = 8,
                            completion: @escaping (VNRequest, Error?) -> Void) -> VNDetectTrajectoriesRequest {
        let req = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero,
                                              trajectoryLength: trajectoryLength,
                                              completionHandler: completion)
        req.objectMinimumNormalizedRadius = 0.008   // a golf ball is small in frame
        req.objectMaximumNormalizedRadius = 0.10
        return req
    }
}
