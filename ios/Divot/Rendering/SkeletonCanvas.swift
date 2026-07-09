// Part of Divot (built + tested; see App/DivotApp.swift).
import SwiftUI
import SwingCore

/// Bone connections for drawing a skeleton (matches the CLI overlay/ghost edges).
enum Skeleton {
    static let edges: [(Joint, Joint)] = [
        (.neck, .nose), (.leftShoulder, .rightShoulder), (.neck, .leftShoulder), (.neck, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist), (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftHip, .rightHip), (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle), (.rightHip, .rightKnee), (.rightKnee, .rightAnkle)
    ]
    static let dots: [Joint] = [.nose, .neck, .leftShoulder, .rightShoulder, .leftElbow, .rightElbow,
                                .leftWrist, .rightWrist, .leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle]
}

/// A video still with the pro ghost (green) and your skeleton (yellow) drawn on top.
/// Points are in top-left screen-normalized coords (0…1).
struct SkeletonCanvas: View {
    let snapshot: FrameExtractor.PhaseSnapshot
    var showGhost = true
    var showUser = true
    var enabledLines: Set<String> = []   // P1.2: any of SwingLines.keys + "handPath" / "headBox"

    private static let lineColors: [String: Color] = [
        "shoulder": .cyan, "hip": .orange, "spine": .purple, "leadArm": .yellow, "swingPlane": .green,
    ]

    var body: some View {
        GeometryReader { geo in
            let size = aspectFit(image: snapshot.image.size, in: geo.size)
            ZStack {
                Image(uiImage: snapshot.image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                Canvas { ctx, _ in
                    drawLines(&ctx, size: size)
                    if showGhost {
                        draw(&ctx, points: snapshot.ghostPoints, size: size,
                             stroke: Color.green.opacity(0.55), lineWidth: 6, dots: false)
                    }
                    if showUser {
                        draw(&ctx, points: snapshot.userPoints, size: size,
                             stroke: Color.yellow.opacity(0.95), lineWidth: 3, dots: true)
                    }
                }
                .frame(width: size.width, height: size.height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func drawLines(_ ctx: inout GraphicsContext, size: CGSize) {
        func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
        for (key, line) in snapshot.lines where enabledLines.contains(key) {
            var p = Path(); p.move(to: pt(line.a)); p.addLine(to: pt(line.b))
            ctx.stroke(p, with: .color(Self.lineColors[key] ?? .white), lineWidth: 2.5)
        }
        if enabledLines.contains("handPath"), snapshot.handPath.count > 1 {
            var p = Path(); p.move(to: pt(snapshot.handPath[0]))
            for c in snapshot.handPath.dropFirst() { p.addLine(to: pt(c)) }
            ctx.stroke(p, with: .color(.mint), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
        }
        if enabledLines.contains("headBox"), snapshot.headBox.width > 0 {
            let r = CGRect(x: snapshot.headBox.minX * size.width, y: snapshot.headBox.minY * size.height,
                           width: snapshot.headBox.width * size.width, height: snapshot.headBox.height * size.height)
            ctx.stroke(Path(r), with: .color(.red), lineWidth: 1.5)
        }
        // Club-path overlays.
        if enabledLines.contains("shaftPlane"), let sp = snapshot.shaftPlane {
            var p = Path(); p.move(to: pt(sp.a)); p.addLine(to: pt(sp.b))
            ctx.stroke(p, with: .color(.green), lineWidth: 3)
        }
        if enabledLines.contains("targetLine"), let tl = snapshot.targetLine {
            var p = Path(); p.move(to: pt(tl.a)); p.addLine(to: pt(tl.b))
            ctx.stroke(p, with: .color(.yellow), style: StrokeStyle(lineWidth: 2.5, dash: [8, 5]))
        }
        if enabledLines.contains("ball") || enabledLines.contains("targetLine"), let b = snapshot.ball {
            let c = pt(b)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(.white))
        }
        if enabledLines.contains("clubHead"), snapshot.clubHeadPath.count > 1 {
            var p = Path(); p.move(to: pt(snapshot.clubHeadPath[0]))
            for c in snapshot.clubHeadPath.dropFirst() { p.addLine(to: pt(c)) }
            ctx.stroke(p, with: .color(.orange), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        if enabledLines.contains("ballFlight"), snapshot.ballFlight.count > 1 {
            var p = Path(); p.move(to: pt(snapshot.ballFlight[0]))
            for c in snapshot.ballFlight.dropFirst() { p.addLine(to: pt(c)) }
            ctx.stroke(p, with: .color(.white), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
    }

    private func draw(_ ctx: inout GraphicsContext, points: [Joint: CGPoint], size: CGSize,
                      stroke: Color, lineWidth: CGFloat, dots: Bool) {
        func P(_ j: Joint) -> CGPoint? {
            guard let p = points[j] else { return nil }
            return CGPoint(x: p.x * size.width, y: p.y * size.height)
        }
        var path = Path()
        for (a, b) in Skeleton.edges {
            if let p1 = P(a), let p2 = P(b) { path.move(to: p1); path.addLine(to: p2) }
        }
        ctx.stroke(path, with: .color(stroke), lineWidth: lineWidth)
        if dots {
            for j in Skeleton.dots {
                if let p = P(j) {
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)),
                             with: .color(.cyan))
                }
            }
        }
    }

    private func aspectFit(image: CGSize, in container: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return container }
        let scale = min(container.width / image.width, container.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}
