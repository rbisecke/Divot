import Foundation

/// The single Vision-dependent seam in the pipeline. Everything downstream of a
/// `PoseSequence` is pure and platform-agnostic, so injecting the provider lets the
/// whole pipeline run where Vision can't (the iOS Simulator has no Neural Engine, so
/// `VNDetectHumanBodyPoseRequest` returns nothing there).
public protocol PoseProvider: Sendable {
    func pose(for video: URL, fps: Double) throws -> PoseSequence
}

/// Real provider — runs Apple Vision. Works on device and on macOS-native.
public struct VisionPoseProvider: PoseProvider {
    public init() {}
    public func pose(for video: URL, fps: Double) throws -> PoseSequence {
        try PoseEstimator.pose(video: video, fps: fps)
    }
}

/// Replay provider — returns a pre-recorded `PoseSequence` (captured once from real
/// Vision on device/macOS and serialized). Lets the Simulator/CI run the exact same
/// downstream analysis with real joint data. Ignores the input URL by design.
public struct ReplayPoseProvider: PoseProvider {
    public let sequence: PoseSequence
    public init(sequence: PoseSequence) { self.sequence = sequence }
    public init(contentsOf url: URL) throws {
        self.sequence = try JSONDecoder().decode(PoseSequence.self, from: Data(contentsOf: url))
    }
    public func pose(for video: URL, fps: Double) throws -> PoseSequence { sequence }
}
