// Part of Divot (built + tested; see App/DivotApp.swift).
// P2.11/P2.12 — live skeleton overlay drawn from the current frame's joints during capture.
// Shares Skeleton.edges/.dots (SkeletonCanvas.swift) as the single source of truth for
// topology; does not reuse SkeletonCanvas itself, which is built around a post-hoc,
// aspect-FIT PhaseSnapshot (ghost + lines + club path) rather than a live, aspect-FILL feed.
import SwiftUI
import SwingCore

struct LiveSkeletonOverlay: View {
    let joints: [Joint: JointPoint]
    /// The active camera format's dimensions, oriented to match the joints' own coordinate
    /// space (portrait — see `CaptureController.liveVideoSize`). `.zero` while the camera
    /// hasn't reported a format yet; nothing is drawn until it's known, rather than guessing.
    let videoSize: CGSize

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                func pt(_ j: Joint) -> CGPoint? {
                    guard videoSize.width > 0, videoSize.height > 0, let p = joints[j] else { return nil }
                    return Self.mapPoint(CGPoint(x: p.x, y: p.y), videoSize: videoSize, viewSize: size)
                }
                var path = Path()
                for (a, b) in Skeleton.edges {
                    if let p1 = pt(a), let p2 = pt(b) { path.move(to: p1); path.addLine(to: p2) }
                }
                ctx.stroke(path, with: .color(.yellow.opacity(0.9)), lineWidth: 3)
                for j in Skeleton.dots {
                    if let p = pt(j) {
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)),
                                 with: .color(.cyan))
                    }
                }
            }
        }
    }

    /// Maps a normalized Vision joint point (0…1, origin bottom-left) into this view's own
    /// coordinate space (top-left origin), accounting for the crop `.resizeAspectFill` applies
    /// when the video's aspect ratio doesn't match the view's.
    ///
    /// `CameraPreview` uses `.resizeAspectFill` (`CaptureView.swift`), which — like
    /// `AVCaptureVideoPreviewLayer` itself — scales the video up just enough to cover the full
    /// view on both axes, then centers and crops whichever axis overflows. A naive
    /// `x * view.width, y * view.height` scale (no crop correction) only lines up with the real
    /// body when the video's aspect ratio happens to equal the view's; in practice a camera
    /// sensor's native aspect ratio (e.g. 4:3 or 16:9) essentially never matches an iPhone
    /// screen's, so that naive version drifts. This performs the same fill-then-center-crop
    /// transform analytically instead of relying on the two ratios happening to match.
    ///
    /// `videoSize` must already be oriented the same way the joints are: this app is
    /// portrait-locked (`UISupportedInterfaceOrientations` = portrait only in `project.yml`),
    /// and `AVCaptureVideoPreviewLayer` rotates the camera's native (landscape-shaped) sensor
    /// buffer to match the interface orientation before applying `videoGravity` — so the size
    /// used for the fill/crop math has to be the portrait-oriented one, not the raw sensor
    /// format's width/height. `CaptureController.liveVideoSize` does that swap.
    static func mapPoint(_ point: CGPoint, videoSize: CGSize, viewSize: CGSize) -> CGPoint {
        guard videoSize.width > 0, videoSize.height > 0 else { return .zero }
        let scale = max(viewSize.width / videoSize.width, viewSize.height / videoSize.height)
        let scaledWidth = videoSize.width * scale
        let scaledHeight = videoSize.height * scale
        let offsetX = (scaledWidth - viewSize.width) / 2
        let offsetY = (scaledHeight - viewSize.height) / 2
        // Vision's normalized coords are bottom-left origin; flip to top-left pixel space first.
        let px = point.x * videoSize.width
        let py = (1 - point.y) * videoSize.height
        return CGPoint(x: px * scale - offsetX, y: py * scale - offsetY)
    }
}
