// Part of Divot (built + tested; see App/DivotApp.swift).
import Foundation
import SwiftUI
import SwingCore

/// Display mapping for the over-the-top / shallowing result (C3). Pure → unit-testable.
enum PlaneFormat {
    static func title(_ plane: PlaneAnalysis) -> String {
        plane.overTheTop ? "Over the top" : "On plane / shallow"
    }
    static func detail(_ plane: PlaneAnalysis) -> String {
        let dev = String(format: "%.2f", plane.maxAbovePlane)
        return plane.overTheTop
            ? "Downswing path is above the plane (dev \(dev)). Feel it drop under the line."
            : "Downswing stays under/along the plane (dev \(dev))."
    }
    static func color(_ plane: PlaneAnalysis) -> Color { plane.overTheTop ? .red : .green }
}

/// Holds the address ball anchor: auto-detected value, overridable by a tap (C2 fallback).
@MainActor
final class BallAnchorModel: ObservableObject {
    @Published private(set) var ball: CGPoint?
    init(detected: CGPoint? = nil) { self.ball = detected }
    /// Manual fallback — a tap sets (or replaces) the anchor.
    func setTap(_ point: CGPoint) { ball = point }
    var isSet: Bool { ball != nil }
}
