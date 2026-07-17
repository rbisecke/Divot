// Part of Divot (built + tested; see App/DivotApp.swift).
import Foundation
import SwingCore

/// Runs the full on-device pipeline off the main thread and reports progress.
@MainActor
final class AnalysisStore: ObservableObject {
    @Published var busy = false
    @Published var phase = ""          // "Importing…" / "Analyzing…"
    @Published var error: String?

    /// Copy the picked video into Documents, run the analysis, and return (Session, filename).
    /// The video is copied first so results survive even if the original is deleted from Photos.
    func analyze(pickedURL: URL, club: ClubSpec, angle: Angle, hand: Hand) async -> (Session, String)? {
        // Re-entrancy guard (finding Low): AnalysisStore is @MainActor, so reads/writes of `busy`
        // are already actor-serialized — a second call arriving while one is in flight (e.g. a
        // double-tap on the import button) would otherwise race the same `dest` file underneath
        // the first call's copy/analyze/cleanup.
        guard !busy else { return nil }
        busy = true; error = nil; phase = "Importing…"
        defer { busy = false; phase = "" }
        // Hoisted above the do block (finding #16) so both catch arms can clean it up: the video
        // is copied into permanent storage *before* analysis runs, so a thrown analysis
        // previously left that copy behind forever with nothing ever removing it.
        let filename = "\(UUID().uuidString).mov"
        let dest = AppPaths.videosDir.appendingPathComponent(filename)
        do {
            try copy(from: pickedURL, to: dest)

            phase = "Analyzing…"
            let session = try await Task.detached(priority: .userInitiated) {
                try SwingAnalyzer.analyzeSession(video: dest, club: club, angle: angle, hand: hand,
                                                 provider: PoseProviderFactory.make())
            }.value
            return (session, filename)
        } catch let e as SwingError {
            try? FileManager.default.removeItem(at: dest)
            error = e.description; return nil
        } catch {
            try? FileManager.default.removeItem(at: dest)
            self.error = error.localizedDescription; return nil
        }
    }

    private func copy(from src: URL, to dest: URL) throws {
        // Security-scoped access is needed for files coming from the Files app / iCloud.
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: src, to: dest)
    }
}
