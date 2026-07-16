// Part of Divot (built + tested; see App/DivotApp.swift).
import SwiftUI
import SwingCore

/// Phase-by-phase overlay of your swing (yellow) with the pro model ghost (green),
/// rescaled to your body and event-aligned. Recomputes pose from the stored clip.
struct GhostCompareView: View {
    let saved: SavedSession
    let swing: SwingAnalysis

    @State private var snapshots: [FrameExtractor.PhaseSnapshot] = []
    @State private var loading = true
    @State private var page = 0
    @State private var showGhost = true
    @State private var enabledLines: Set<String> = []

    private let lineOptions: [(key: String, label: String)] = [
        ("shoulder", "Shoulders"), ("hip", "Hips"), ("spine", "Spine"),
        ("leadArm", "Lead arm"), ("swingPlane", "Plane"), ("handPath", "Hand path"), ("headBox", "Head"),
    ]

    var body: some View {
        VStack {
            if loading {
                ProgressView("Rendering overlay…").frame(maxHeight: .infinity)
            } else if snapshots.isEmpty {
                ContentUnavailableView("Couldn’t build overlay", systemImage: "figure.golf")
            } else {
                TabView(selection: $page) {
                    ForEach(Array(snapshots.enumerated()), id: \.offset) { i, snap in
                        VStack {
                            SkeletonCanvas(snapshot: snap, showGhost: showGhost, enabledLines: enabledLines)
                                .background(Color.black)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            Text(snap.phase.rawValue.capitalized).font(.headline).padding(.top, 4)
                        }
                        .padding()
                        .tag(i)
                    }
                }
                .tabViewStyle(.page)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(lineOptions, id: \.key) { opt in
                            let on = enabledLines.contains(opt.key)
                            Button {
                                if on { enabledLines.remove(opt.key) } else { enabledLines.insert(opt.key) }
                            } label: {
                                Text(opt.label).font(.caption)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(on ? Color.accentColor : Color.gray.opacity(0.2), in: Capsule())
                                    .foregroundStyle(on ? .white : .primary)
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                HStack(spacing: 16) {
                    Label("You", systemImage: "circle.fill").foregroundStyle(.yellow)
                    Label("Pro (ghost)", systemImage: "circle.fill").foregroundStyle(.green)
                    Spacer()
                    Toggle("Ghost", isOn: $showGhost).labelsHidden()
                }
                .font(.footnote)
                .padding(.horizontal)
            }
        }
        .navigationTitle("Ghost overlay")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let session = saved.session else { loading = false; return }
        let snaps = await FrameExtractor.snapshots(videoURL: saved.videoURL, cacheURL: saved.poseCacheURL, session: session, swing: swing)
        snapshots = snaps
        loading = false
    }
}
