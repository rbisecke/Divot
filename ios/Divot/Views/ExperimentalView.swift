// Part of Divot (built + tested; see App/DivotApp.swift).
import SwiftUI

/// Surfaces the P3 experimental, device-only features. Gated by the Settings toggle.
/// These are wired but require an on-device spike to validate/enable (see EXPERIMENTAL.md).
struct ExperimentalView: View {
    var body: some View {
        List {
            Section {
                Text("These are wired but unproven on this build. They need a real iPhone (and, for DockKit, an accessory). See EXPERIMENTAL.md.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            row("3D setup-frame avatar", "VNDetectHumanBodyPose3DRequest on the address frame only. Jittery on motion — setup pose only.", "needs a device")
            row("Ball flight tracking", "VNDetectTrajectoriesRequest, stationary/tripod camera. High risk; club-head tracking not shipping.", "needs a device + spike")
            row("Motorized stand (DockKit)", DockKitService.statusText, DockKitService.isSupported ? "needs an accessory" : "unavailable")
        }
        .navigationTitle("Experimental")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ detail: String, _ status: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(status).font(.caption2).padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2), in: Capsule()).foregroundStyle(.orange)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
