// D4 — TipKit tips for the least-discoverable controls, plus a pure eligibility gate
// (TipGate) so the show-once / usage-gated logic is unit-testable without the TipKit runtime.
import Foundation
import TipKit

/// Pure, testable model of "show a tip at most N times, once the user has done something M times."
struct TipGate: Equatable {
    var timesShown: Int
    var usageEvents: Int
    var maxShows: Int = 1
    var minUsage: Int = 1
    var shouldShow: Bool { timesShown < maxShows && usageEvents >= minUsage }
}

@available(iOS 17.0, *)
struct ChartScrubTip: Tip {
    var title: Text { Text("Scrub the trend") }
    var message: Text? { Text("Drag across the chart to read a day's value.") }
    var image: Image? { Image(systemName: "hand.draw") }
}

@available(iOS 17.0, *)
struct OverlayToggleTip: Tip {
    var title: Text { Text("Toggle the overlays") }
    var message: Text? { Text("Show or hide the swing-plane line, hand path, and ghost.") }
    var image: Image? { Image(systemName: "square.stack.3d.up") }
}

@available(iOS 17.0, *)
struct BallTapTip: Tip {
    var title: Text { Text("Place the ball") }
    var message: Text? { Text("Tap the ball at address to anchor the target and plane lines.") }
    var image: Image? { Image(systemName: "smallcircle.filled.circle") }
}
