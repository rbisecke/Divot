import Foundation
import CoreGraphics
import Vision
import AVFoundation
import CoreMedia

// C4 — post-impact ball-flight trace. `link` is pure (testable). `trace` uses
// VNDetectTrajectoriesRequest (parabolic, stationary camera) — device-gated; returns
// empty on the Simulator/macOS, which is fine.

public struct BallFlight: Codable, Sendable {
    public let points: [CGPoint]
    public let detected: Bool
    public init(points: [CGPoint], detected: Bool) { self.points = points; self.detected = detected }
}

public enum BallFlightTracer {

    /// Order raw (point, confidence) observations into a smoothed flight polyline. Pure.
    public static func link(_ observations: [(CGPoint, Double)]) -> [CGPoint] {
        let pts = observations.filter { $0.0.x.isFinite && $0.0.y.isFinite && $0.1 > 0 }.map { $0.0 }
        guard pts.count >= 2 else { return pts }
        let sorted = pts.sorted { $0.x < $1.x }   // flight progresses across the frame
        // light moving-average smoothing
        var out: [CGPoint] = []
        for i in 0..<sorted.count {
            let lo = max(0, i - 1), hi = min(sorted.count - 1, i + 1)
            var sx = 0.0, sy = 0.0, c = 0.0
            for k in lo...hi { sx += Double(sorted[k].x); sy += Double(sorted[k].y); c += 1 }
            out.append(CGPoint(x: sx / c, y: sy / c))
        }
        return out
    }

    /// Device path: detect the ball's parabolic flight from a clip. Reads CMSampleBuffers via
    /// AVAssetReader so each frame carries a presentation timestamp — VNDetectTrajectoriesRequest
    /// is stateful and needs the time base to fit a parabola (bare CGImages yield nothing).
    /// Device-gated: returns empty on the Simulator/macOS (no trajectory model).
    public static func trace(videoURL: URL, roi: CGRect? = nil) -> BallFlight {
        let asset = AVURLAsset(url: videoURL)
        guard let track = asset.tracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return BallFlight(points: [], detected: false) }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return BallFlight(points: [], detected: false) }
        reader.add(output)

        // Keep the longest trajectory the request builds — its detectedPoints are already ordered.
        var best: [CGPoint] = []
        let req = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero, trajectoryLength: 5) { request, _ in
            for obs in (request.results as? [VNTrajectoryObservation]) ?? [] where obs.detectedPoints.count >= best.count {
                best = obs.detectedPoints.map { CGPoint(x: $0.location.x, y: 1 - $0.location.y) }
            }
        }
        if let roi = roi { req.regionOfInterest = roi }
        // A golf ball / synthetic dot is a small high-contrast object; widen the radius band.
        req.objectMinimumNormalizedRadius = 0.003
        req.objectMaximumNormalizedRadius = 0.30

        let handler = VNSequenceRequestHandler()
        reader.startReading()
        while reader.status == .reading, let sb = output.copyNextSampleBuffer() {
            try? handler.perform([req], on: sb)
            CMSampleBufferInvalidate(sb)
        }
        return BallFlight(points: best, detected: best.count >= 5)
    }
}
