// Part of Divot (built + tested; see App/DivotApp.swift).
// ⚠️ EXPERIMENTAL, DEVICE-ONLY. Vision returns nothing on the Simulator; see EXPERIMENTAL.md.
import Foundation
import Vision
import CoreGraphics

/// P3.2 — 3D body pose on the (near-static) address frame only. Not used for motion:
/// VNDetectHumanBodyPose3DRequest is still-image oriented and jitters on the downswing.
enum Pose3DService {
    struct Result3D { let jointCount: Int; let bodyHeightMeters: Float? }

    /// Runs 3D pose on a single frame. Returns nil on the Simulator / when nothing is detected.
    static func analyze(_ cgImage: CGImage) -> Result3D? {
        let request = VNDetectHumanBodyPose3DRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let obs = request.results?.first else { return nil }
        return Result3D(jointCount: obs.availableJointNames.count, bodyHeightMeters: obs.bodyHeight)
    }
}
