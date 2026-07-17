// Part of Divot (built + tested; see App/DivotApp.swift).
// P2.2 — event-synced side-by-side of two of your own swings.
import SwiftUI
import SwiftData
import AVKit
import SwingCore

/// Tab entry: pick two saved swings to compare.
struct CompareView: View {
    @Query(sort: \SavedSession.date, order: .reverse) private var sessions: [SavedSession]
    @State private var a: SavedSession?
    @State private var b: SavedSession?

    var body: some View {
        NavigationStack {
            List {
                Section("Older swing (A)") { picker($a) }
                Section("Newer swing (B)") { picker($b) }
                if let a, let b, a.id != b.id {
                    NavigationLink {
                        SideBySideView(a: a, b: b)
                    } label: { Label("Compare A vs B", systemImage: "rectangle.split.2x1") }
                }
            }
            .listRowBackground(Color.surface)
            .divotScreenBackground()
            .overlay {
                if sessions.count < 2 {
                    let e = EmptyStateContent.forTab(.compare)
                    ContentUnavailableView(e.title, systemImage: e.symbol, description: Text(e.message))
                }
            }
            .navigationTitle("Compare")
        }
    }

    private func picker(_ sel: Binding<SavedSession?>) -> some View {
        ForEach(sessions) { s in
            Button {
                sel.wrappedValue = s
            } label: {
                HStack {
                    Text("\(s.club.displayName) · \(s.date, format: .dateTime.month().day().hour().minute())")
                    Spacer()
                    if sel.wrappedValue?.id == s.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
            }
            .buttonStyle(.plain)
        }
    }
}

/// Two players scrubbed together; B's time is event-aligned to A via EventAlignment.
struct SideBySideView: View {
    let a: SavedSession
    let b: SavedSession

    @State private var playerA = AVPlayer()
    @State private var playerB = AVPlayer()
    @State private var pos: Double = 0          // 0…1 across swing A (address→finish)
    @State private var matchText = "…"

    private var eventsA: SwingEvents? { a.session?.swings.first?.events }
    private var eventsB: SwingEvents? { b.session?.swings.first?.events }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                VideoPlayer(player: playerA)
                VideoPlayer(player: playerB)
            }
            .frame(height: 300)

            Slider(value: $pos, in: 0...1) { _ in seek() }
            HStack { Text("A: \(a.club.displayName)").font(.caption); Spacer(); Text("B: \(b.club.displayName)").font(.caption) }
                .foregroundStyle(.secondary)

            Label("Shape match A↔B: \(matchText)", systemImage: "figure.golf")
                .font(.subheadline)
        }
        .padding()
        .navigationTitle("Side by side")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            playerA.replaceCurrentItem(with: AVPlayerItem(url: a.videoURL))
            playerB.replaceCurrentItem(with: AVPlayerItem(url: b.videoURL))
        }
        // seek() called synchronously right after replaceCurrentItem used to no-op (an
        // AVPlayerItem isn't seekable until it reaches .readyToPlay), silently leaving both
        // players on frame 0 instead of the event-aligned start (Medium finding). Waits for both
        // items' readiness first.
        .task {
            await waitUntilReady(playerA)
            await waitUntilReady(playerB)
            seek()
        }
        .task { await computeMatch() }
    }

    private func waitUntilReady(_ player: AVPlayer) async {
        guard let item = player.currentItem else { return }
        for _ in 0..<50 {
            if item.status == .readyToPlay || item.status == .failed { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func seek() {
        guard let ea = eventsA else { return }
        let tA = ea.address.t + (ea.finish.t - ea.address.t) * pos
        let tB = eventsB.map { EventAlignment.mapTime(tA, from: ea, to: $0) } ?? tA
        playerA.seek(to: CMTime(seconds: tA, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playerB.seek(to: CMTime(seconds: tB, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Overall shape match between the two swings (device-only: needs pose for both).
    /// Not `Task.detached`: this view isn't @MainActor-isolated and none of
    /// PoseCache/TemplateBuilder/PoseComparator are actor-isolated either, so detaching was never
    /// actually necessary — it only meant this work didn't inherit the parent `.task`'s
    /// cancellation, so backing out of the screen let it keep running to completion in the
    /// background (finding #13's Task.detached cancellation fix, landed with its cache call-site
    /// change since both touch these lines).
    private func computeMatch() async {
        guard let sA = a.session?.swings.first, let sB = b.session?.swings.first else { matchText = "n/a"; return }
        let urlA = a.videoURL, urlB = b.videoURL
        let cacheA = a.poseCacheURL, cacheB = b.poseCacheURL
        let catA = a.club.category, angleA = a.angle, catB = b.club.category, angleB = b.angle
        let evA = sA.events, evB = sB.events
        guard let poseA = await PoseCache.devicePose(videoURL: urlA, cacheURL: cacheA),
              let poseB = await PoseCache.devicePose(videoURL: urlB, cacheURL: cacheB),
              !Task.isCancelled else {
            if !Task.isCancelled { matchText = "on-device only" }
            return
        }
        let tA = TemplateBuilder.build(poseA, events: evA, category: catA, angle: angleA)
        let tB = TemplateBuilder.build(poseB, events: evB, category: catB, angle: angleB)
        let result = PoseComparator.compare(user: tA, reference: tB, category: catA, angle: angleA).overall
        guard !Task.isCancelled else { return }
        matchText = "\(Int(result * 100))%"
    }
}
