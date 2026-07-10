// Part of Divot (built + tested; see App/DivotApp.swift).
// P2.1 — guided recorder UI. DEVICE-GATED (no camera on the Simulator).
import SwiftUI
import AVFoundation
import SwingCore

struct CaptureView: View {
    var onCaptured: (URL) -> Void
    @StateObject private var cap = CaptureController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            CameraPreview(session: cap.session).ignoresSafeArea()

            // Framing guide: silhouette frame turns green when the body is fully in view.
            RoundedRectangle(cornerRadius: 24)
                .stroke(cap.framingOK ? Color.green : Color.white.opacity(0.6),
                        style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                .padding(28).ignoresSafeArea()

            VStack {
                Label(cap.framingOK ? "In frame ✓" : cap.framingReason,
                      systemImage: cap.framingOK ? "checkmark.circle.fill" : "person.fill.viewfinder")
                    .padding(8).background(.black.opacity(0.5), in: Capsule())
                    .foregroundStyle(cap.framingOK ? .green : .white)
                    .padding(.top, 56)
                if cap.highFps {
                    Text("High-speed capture").font(.caption2).foregroundStyle(.white.opacity(0.8))
                }
                Picker("View", selection: $cap.dtlMode) {
                    Text("Face-on").tag(false)
                    Text("Down-the-line").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                .padding(.top, 6)
                Spacer()
                if cap.isRecording {
                    Label("Recording…", systemImage: "record.circle").foregroundStyle(.red)
                        .symbolEffect(.pulse)   // D1 — animate the recording indicator
                        .padding(8).background(.black.opacity(0.5), in: Capsule())
                    // P2.11 — live swing-phase chip, causally detected from the same speed
                    // sample as the recording trigger (see LivePhaseDetector).
                    Text(cap.livePhase.rawValue.capitalized)
                        .font(.footnote).foregroundStyle(.white)
                        .padding(8).background(.black.opacity(0.5), in: Capsule())
                        .padding(.top, 6)
                } else {
                    Text("Make your swing — recording starts automatically")
                        .font(.footnote).foregroundStyle(.white)
                        .padding(8).background(.black.opacity(0.5), in: Capsule())
                }
                Spacer().frame(height: 30)
            }
        }
        .overlay {
            if cap.permissionDenied {
                ContentUnavailableView("Camera access needed",
                    systemImage: "camera.fill",
                    description: Text("Enable camera access in Settings to record swings."))
                    .background(.background)
            }
        }
        // Controls sit above every overlay so Cancel works even when access is denied.
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
                    .background(.black.opacity(0.5), in: Circle()).foregroundStyle(.white)
            }
            .accessibilityLabel("Cancel")
            .padding(.horizontal, 16).padding(.top, 8)
        }
        .overlay(alignment: .topTrailing) {
            if !cap.permissionDenied {
                Button { cap.switchCamera() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera").font(.headline).frame(width: 44, height: 44)
                        .background(.black.opacity(0.5), in: Circle()).foregroundStyle(.white)
                }
                .accessibilityLabel(cap.cameraPosition == .back ? "Switch to front camera" : "Switch to back camera")
                .disabled(cap.isRecording)
                .padding(.horizontal, 16).padding(.top, 8)
            }
        }
        .onAppear { cap.requestAndConfigure() }
        .onDisappear { cap.stop() }
        .onChange(of: cap.lastClipURL) { _, url in
            if let url { onCaptured(url); dismiss() }
        }
        // P2.10 — start/stop haptics: light tap when recording begins, success tap when it ends.
        .sensoryFeedback(.impact(weight: .light), trigger: cap.isRecording) { old, new in !old && new }
        .sensoryFeedback(.success, trigger: cap.isRecording) { old, new in old && !new }
    }
}

/// Bridges an AVCaptureSession to a SwiftUI view via AVCaptureVideoPreviewLayer.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView(); v.videoLayer.session = session; v.videoLayer.videoGravity = .resizeAspectFill; return v
    }
    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
