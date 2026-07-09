// Part of Divot (built + tested; see App/DivotApp.swift).
import SwiftUI
import UIKit
import AVFoundation
import SwingCore

/// P1.1 — pure scrubber math (testable without playback).
enum ScrubberMath {
    /// Event marks as normalized [0,1] positions along the clip duration, in A/T/I/F order.
    static func normalizedTicks(_ events: SwingEvents, duration: Double) -> [(phase: Phase, pos: Double)] {
        guard duration > 0 else { return [] }
        let raw: [(Phase, Double)] = [(.address, events.address.t), (.top, events.top.t),
                                      (.impact, events.impact.t), (.finish, events.finish.t)]
        var out: [(phase: Phase, pos: Double)] = []
        for (phase, t) in raw {
            out.append((phase: phase, pos: min(1.0, max(0.0, t / duration))))
        }
        return out
    }
    /// Below ~60fps, slow-motion duplicates frames and impact blurs.
    static func showsLowFpsNotice(_ fps: Float) -> Bool { fps < 60 }
}

@MainActor
final class SwingPlayerModel: ObservableObject {
    let player: AVPlayer
    let duration: Double
    let nominalFrameRate: Float
    @Published var current: Double = 0
    @Published var rate: Float = 0
    private var observer: Any?
    private let frameDur: Double

    init(url: URL) {
        let asset = AVURLAsset(url: url)
        player = AVPlayer(url: url)
        let dur = CMTimeGetSeconds(asset.duration)
        duration = dur.isFinite ? dur : 0
        let fps = asset.tracks(withMediaType: .video).first?.nominalFrameRate ?? 30
        nominalFrameRate = fps
        frameDur = fps > 0 ? 1.0 / Double(fps) : 1.0 / 30
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.03, preferredTimescale: 600), queue: .main) { [weak self] t in
            self?.current = CMTimeGetSeconds(t)
        }
    }
    deinit { if let o = observer { player.removeTimeObserver(o) } }

    func seek(toFraction f: Double) { seek(to: f * duration) }
    func seek(to t: Double) {
        player.seek(to: CMTime(seconds: max(0, min(duration, t)), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func step(_ dir: Int) { player.pause(); rate = 0; seek(to: current + Double(dir) * frameDur) }
    func setRate(_ r: Float) { rate = r; player.rate = r }
    func playPause() { setRate(rate == 0 ? 1 : 0) }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerUIView { let v = PlayerUIView(); v.playerLayer.player = player; return v }
    func updateUIView(_ uiView: PlayerUIView, context: Context) {}
}
final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    override init(frame: CGRect) { super.init(frame: frame); playerLayer.videoGravity = .resizeAspect }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
}

struct SwingPlayerView: View {
    @StateObject private var model: SwingPlayerModel
    let events: SwingEvents
    private let rates: [Float] = [1, 0.5, 0.25, 0.125]

    init(url: URL, events: SwingEvents) {
        _model = StateObject(wrappedValue: SwingPlayerModel(url: url))
        self.events = events
    }

    var body: some View {
        VStack(spacing: 12) {
            PlayerLayerView(player: model.player)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if ScrubberMath.showsLowFpsNotice(model.nominalFrameRate) {
                Label("\(Int(model.nominalFrameRate))fps source — impact may blur at slow speeds",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            scrubber
            controls
            Spacer()
        }
        .padding()
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var scrubber: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let playheadX = (model.duration > 0 ? model.current / model.duration : 0) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.3)).frame(height: 6)
                ForEach(ScrubberMath.normalizedTicks(events, duration: model.duration), id: \.phase) { tick in
                    Rectangle().fill(Color.accentColor).frame(width: 2, height: 18)
                        .offset(x: tick.pos * w - 1)
                }
                Circle().fill(.white).frame(width: 15, height: 15)
                    .shadow(radius: 2)
                    .offset(x: max(0, min(w, playheadX)) - 7.5)
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                model.setRate(0)
                model.seek(toFraction: min(1, max(0, g.location.x / w)))
            })
        }
        .frame(height: 22)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button { model.step(-1) } label: { Image(systemName: "backward.frame.fill") }
            Button { model.playPause() } label: { Image(systemName: model.rate == 0 ? "play.fill" : "pause.fill") }
            Button { model.step(1) } label: { Image(systemName: "forward.frame.fill") }
            Spacer()
            ForEach(rates, id: \.self) { r in
                Button { model.setRate(r) } label: {
                    Text(rateLabel(r)).font(.caption.bold())
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(model.rate == r ? Color.accentColor : Color.gray.opacity(0.2), in: Capsule())
                        .foregroundStyle(model.rate == r ? .white : .primary)
                }
            }
        }
        .font(.title3)
    }

    private func rateLabel(_ r: Float) -> String {
        switch r { case 1: return "1×"; case 0.5: return "½×"; case 0.25: return "¼×"; default: return "⅛×" }
    }
}
