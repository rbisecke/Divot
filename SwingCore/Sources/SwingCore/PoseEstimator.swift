import Foundation
import AVFoundation
import Vision
import CoreGraphics

/// Stage ③ — per-frame 2D body pose via Apple Vision (Neural Engine on device).
/// Ported from the validated CLI `poseextract`. Same API on iOS and macOS.
public enum PoseEstimator {

    private static let jointMap: [(VNHumanBodyPoseObservation.JointName, Joint)] = [
        (.nose, .nose), (.leftEye, .leftEye), (.rightEye, .rightEye), (.leftEar, .leftEar), (.rightEar, .rightEar),
        (.neck, .neck), (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
        (.leftElbow, .leftElbow), (.rightElbow, .rightElbow), (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
        (.leftHip, .leftHip), (.rightHip, .rightHip), (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
        (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle), (.root, .root)
    ]

    /// Extract pose at `fps` (default 30 to match the CLI/fixtures).
    /// Vision coords are normalized (0…1, origin bottom-left) + confidence.
    public static func pose(video: URL, fps: Double = 30, minConfidence: Float = 0.15) throws -> PoseSequence {
        let asset = AVURLAsset(url: video)
        let dur = CMTimeGetSeconds(asset.duration)
        guard dur.isFinite, dur > 0 else { throw SwingError.unreadableVideo(video) }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.008, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.008, preferredTimescale: 600)

        let step = 1.0 / fps
        let n = max(1, Int(dur / step))
        var frames: [PoseFrame] = []
        var w = 0, h = 0

        for i in 0..<n {
            let t = Double(i) * step
            guard let cg = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) else { continue }
            if w == 0 { w = cg.width; h = cg.height }
            let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
            let req = VNDetectHumanBodyPoseRequest()
            try? handler.perform([req])
            var joints: [Joint: JointPoint] = [:]
            if let obs = req.results?.first as? VNHumanBodyPoseObservation,
               let recognized = try? obs.recognizedPoints(.all) {
                for (vn, j) in jointMap {
                    if let p = recognized[vn], p.confidence >= minConfidence {
                        joints[j] = JointPoint(x: Double(p.location.x), y: Double(p.location.y), c: Double(p.confidence))
                    }
                }
            }
            frames.append(PoseFrame(t: t, joints: joints))
        }
        return PoseSequence(fps: fps, width: w, height: h, frames: frames)
    }
}

public enum SwingError: Error, CustomStringConvertible {
    case unreadableVideo(URL)
    case noSwingDetected
    case lowPoseConfidence
    public var description: String {
        switch self {
        case .unreadableVideo(let u): return "Could not read video: \(u.lastPathComponent)"
        case .noSwingDetected: return "No swing detected in the clip."
        case .lowPoseConfidence: return "Low pose confidence — better light / full body in frame."
        }
    }
}
