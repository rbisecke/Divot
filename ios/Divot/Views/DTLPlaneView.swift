// Part of Divot (built + tested; see App/DivotApp.swift).
import SwiftUI
import AVFoundation
import SwingCore

/// C1/C2/C4/C5 — plane + target line + hand-path (and experimental club-head / ball-flight)
/// overlays for over-the-top / shallowing review. Best on down-the-line; face-on labels the plane "approx".
struct DTLPlaneView: View {
    let saved: SavedSession
    let swing: SwingAnalysis

    @State private var snaps: [FrameExtractor.PhaseSnapshot] = []
    @State private var page = 0
    @State private var loading = true
    @StateObject private var ballAnchor = BallAnchorModel()

    // overlay toggles
    @State private var showPlane = true
    @State private var showTarget = true
    @State private var showHand = true
    @State private var showClub = false
    @State private var showFlight = false

    private var isDTL: Bool { saved.angle == .dtl }

    private var enabled: Set<String> {
        var s = Set<String>()
        if showPlane { s.insert("shaftPlane"); s.insert("swingPlane") }
        if showTarget { s.insert("targetLine"); s.insert("ball") }
        if showHand { s.insert("handPath") }
        if showClub { s.insert("clubHead") }
        if showFlight { s.insert("ballFlight") }
        return s
    }

    var body: some View {
        VStack(spacing: 8) {
            if let plane = swing.plane { overTheTopBanner(plane) }
            if loading {
                ProgressView("Rendering overlays…").frame(maxHeight: .infinity)
            } else if snaps.isEmpty {
                ContentUnavailableView("Couldn’t build overlay", systemImage: "scope").frame(maxHeight: .infinity)
            } else {
                TabView(selection: $page) {
                    ForEach(Array(snaps.enumerated()), id: \.offset) { i, snap in
                        VStack(spacing: 4) {
                            GeometryReader { geo in
                                SkeletonCanvas(snapshot: snap, showGhost: false, showUser: false, enabledLines: enabled)
                                    .background(Color.black)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(alignment: .bottomLeading) { tapHint(snap) }
                                    .contentShape(Rectangle())
                                    .gesture(SpatialTapGesture().onEnded { e in
                                        guard snap.phase == .address, geo.size.width > 0, geo.size.height > 0 else { return }
                                        let n = CGPoint(x: min(max(e.location.x / geo.size.width, 0), 1),
                                                        y: min(max(e.location.y / geo.size.height, 0), 1))
                                        Task { await setBall(n) }
                                    })
                            }
                            Text(snap.phase.rawValue.capitalized).font(.headline)
                        }.padding(.horizontal).tag(i)
                    }
                }
                .tabViewStyle(.page)
                controls
            }
        }
        .navigationTitle("Plane & path")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func overTheTopBanner(_ plane: PlaneAnalysis) -> some View {
        HStack {
            Image(systemName: plane.overTheTop ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(PlaneFormat.title(plane)).bold()
                Text(PlaneFormat.detail(plane)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(PlaneFormat.color(plane).opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                toggle("Plane", $showPlane, .green)
                toggle("Target", $showTarget, .yellow)
                toggle("Hand", $showHand, .mint)
                toggle("Club·exp", $showClub, .orange)
            }
            HStack {
                if !isDTL { Text("Face-on: plane is approximate").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                Button {
                    Task { await traceBallFlight() }
                } label: { Label("Trace ball flight", systemImage: "arrow.up.forward") }
                    .font(.caption).buttonStyle(.bordered)
            }.padding(.horizontal)
        }
        .padding(.bottom, 6)
    }

    private func toggle(_ label: String, _ bind: Binding<Bool>, _ color: Color) -> some View {
        Button { bind.wrappedValue.toggle() } label: {
            Text(label).font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                .background(bind.wrappedValue ? color.opacity(0.3) : Color(.secondarySystemBackground),
                           in: Capsule())
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func tapHint(_ snap: FrameExtractor.PhaseSnapshot) -> some View {
        if snap.phase == .address && snap.ball == nil {
            Text("Tap the ball to set the line").font(.caption2)
                .padding(6).background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white).padding(8)
        }
    }

    private func setBall(_ normalized: CGPoint) async {
        ballAnchor.setTap(normalized)
        await load()
    }

    private func load() async {
        loading = true
        let snapshots = await FrameExtractor.snapshots(videoURL: saved.videoURL, cacheURL: saved.poseCacheURL,
                                                       session: saved.session ?? placeholder(),
                                                       swing: swing, ball: ballAnchor.ball)
        snaps = snapshots
        if ballAnchor.ball == nil, let b = snapshots.first?.ball { ballAnchor.setTap(b) }
        loading = false
    }

    private func traceBallFlight() async {
        // C4 — device-gated; VNDetectTrajectories returns nothing on the Simulator.
        // Reads the clip via AVAssetReader (CMSampleBuffer timestamps) inside the tracer.
        let flight = BallFlightTracer.trace(videoURL: saved.videoURL, roi: nil)
        if flight.detected {
            showFlight = true
            // rebuild snaps carrying the flight
            snaps = snaps.map { var s = $0; s.ballFlight = flight.points; return s }
        } else {
            showFlight = true   // toggle on; overlay simply shows nothing (honest empty state)
        }
    }

    private func placeholder() -> Session {
        Session(date: saved.date, club: saved.club, angle: saved.angle, hand: saved.hand, swings: [swing], stats: nil)
    }
}
