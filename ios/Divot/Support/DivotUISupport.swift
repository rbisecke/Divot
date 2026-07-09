// Divot UI support — fixed data-viz coding, empty-state content, chart-scrub resolver.
import SwiftUI
import SwingCore

/// Fixed color coding reused across Analyze / Trends / Compare so a color always means one thing.
enum DataVizRole {
    case you, reference, offPlane
    var color: Color {
        switch self {
        case .you: return .dataYou
        case .reference: return .dataReference
        case .offPlane: return .warn
        }
    }
}

/// Branded empty-state content per tab (title / SF Symbol / message).
struct EmptyStateContent: Equatable {
    let title: String
    let symbol: String
    let message: String

    static func forTab(_ tab: Tab) -> EmptyStateContent {
        switch tab {
        case .history:
            return .init(title: "No sessions yet", symbol: "figure.golf",
                         message: "Record or import a swing to see it here.")
        case .trends:
            return .init(title: "No trends yet", symbol: "chart.xyaxis.line",
                         message: "Analyze a few swings to watch progress over time.")
        case .compare:
            return .init(title: "Nothing to compare", symbol: "rectangle.split.2x1",
                         message: "Analyze at least two swings, then line them up.")
        }
    }
    enum Tab { case history, trends, compare }
}

/// Pure resolver for chart scrubbing: the point nearest a scrubbed date.
enum ChartScrub {
    static func nearest(to date: Date, in pts: [(date: Date, value: Double)]) -> (date: Date, value: Double)? {
        pts.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }
}

extension View {
    /// Dark-first screen background for Form/List/ScrollView-based screens.
    func divotScreenBackground() -> some View {
        self.scrollContentBackground(.hidden).background(Color.bg)
    }
}

/// The recurring swing-plane motif: a short accent line (used as a spark on rows/headers).
struct PlaneSpark: View {
    var width: CGFloat = 34
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            p.move(to: CGPoint(x: 0, y: size.height))
            p.addLine(to: CGPoint(x: size.width, y: 0))
            ctx.stroke(p, with: .color(.brand), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: -2, y: size.height - 4, width: 6, height: 6)), with: .color(.brand))
        }
        .frame(width: width, height: 12)
    }
}
