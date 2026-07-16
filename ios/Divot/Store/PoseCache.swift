// Part of Divot (built + tested; see App/DivotApp.swift).
// P2.1 — cache the single most expensive operation in the app (full frame decode + per-frame
// Vision) so review screens read a persisted PoseSequence instead of recomputing it from scratch
// on every visit (finding #13). PoseSequence is already Codable — ReplayPoseProvider already
// round-trips it as JSON (sample_swing.pose.json) — so this reuses that exact format rather than
// inventing a new cache representation.
import Foundation
import SwingCore

enum PoseCache {
    private static func cached(at url: URL) -> PoseSequence? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PoseSequence.self, from: data)
    }

    private static func store(_ seq: PoseSequence, at url: URL) {
        guard let data = try? JSONEncoder().encode(seq) else { return }
        try? data.write(to: url)
    }

    /// Review screens (Ghost/DTL/Side-by-side) — replay-backed on the Simulator, real Vision on
    /// device, matching PoseProviderFactory's own selection.
    static func pose(videoURL: URL, cacheURL: URL, fps: Double = 30) async -> PoseSequence? {
        if let hit = cached(at: cacheURL) { return hit }
        guard let seq = try? PoseProviderFactory.make().pose(for: videoURL, fps: fps) else { return nil }
        store(seq, at: cacheURL)
        return seq
    }

    /// Device-gated motion analysis (P2.3/P2.4) — always real Vision, nil on the Simulator by
    /// design (kinematic fidelity requires the real pipeline, not the replayed fixture), so this
    /// must not silently fall back to replay data there.
    static func devicePose(videoURL: URL, cacheURL: URL) async -> PoseSequence? {
        if let hit = cached(at: cacheURL) { return hit }
        guard let seq = try? PoseEstimator.pose(video: videoURL), !seq.frames.isEmpty else { return nil }
        store(seq, at: cacheURL)
        return seq
    }
}
