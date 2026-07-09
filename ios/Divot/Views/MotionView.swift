// Part of Divot (built + tested; see App/DivotApp.swift).
// P2.3/P2.4 — kinematic sequence + head travel. DEVICE-GATED (needs on-device pose).
import SwiftUI
import SwingCore

struct MotionView: View {
    let saved: SavedSession
    let swing: SwingAnalysis

    @State private var motion: FrameExtractor.Motion?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if loading {
                    ProgressView("Analyzing motion…").frame(maxWidth: .infinity).padding(.top, 40)
                } else if let m = motion {
                    sequenceCard(m.sequence)
                    headCard(m.headTravelCm)
                } else {
                    ContentUnavailableView("On-device only", systemImage: "iphone",
                        description: Text("Kinematic sequence needs body-pose, which runs on your iPhone (not the Simulator)."))
                        .padding(.top, 40)
                }
            }
            .padding()
        }
        .navigationTitle("Motion")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func sequenceCard(_ seq: KinematicSequence) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Kinematic sequence").font(.headline)
                Spacer()
                Label(seq.inSequence ? "In sequence" : "Out of sequence",
                      systemImage: seq.inSequence ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(seq.inSequence ? .green : .orange)
            }
            Text("Peak speed order (2D estimate): " + seq.order.joined(separator: " → "))
                .font(.subheadline).foregroundStyle(.secondary)
            let base = seq.peakTimes.values.min() ?? 0
            ForEach(seq.order, id: \.self) { seg in
                if let t = seq.peakTimes[seg] {
                    HStack {
                        Text(seg.capitalized).frame(width: 70, alignment: .leading).font(.caption)
                        Text(String(format: "+%.2fs", t - base)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Text("A good swing fires proximal → distal: pelvis, torso, arm, hand.")
                .font(.caption2).foregroundStyle(Color.textMuted)
        }
        .padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func headCard(_ cm: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Head movement").font(.headline)
            Text(String(format: "%.1f cm of head travel through the swing", cm))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func load() async {
        motion = await FrameExtractor.motion(videoURL: saved.videoURL, swing: swing, angle: saved.angle, hand: saved.hand)
        loading = false
    }
}
