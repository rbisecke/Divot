// Part of Divot (built + tested; see App/DivotApp.swift).
import SwiftUI
import SwingCore

/// Persisted user preferences (handedness + defaults) via @AppStorage.
enum SettingsKey {
    static let hand = "settings.hand"
    static let club = "settings.club"
    static let angle = "settings.angle"
    static let experimental = "settings.experimental"
}

// Display helpers for the SwingCore enums used in pickers.
extension Hand {
    static let all: [Hand] = [.right, .left]
    var label: String { self == .right ? "Right-handed" : "Left-handed" }
}

extension SwingCore.Angle {
    static let all: [SwingCore.Angle] = [.faceOn, .dtl]
    var label: String { self == .faceOn ? "Face-on" : "Down-the-line" }
}

extension ClubCategory {
    var label: String {
        switch self {
        case .driver: return "Driver"
        case .wood: return "Wood"
        case .hybrid: return "Hybrid"
        case .drivingIron: return "Driving iron"
        case .iron: return "Iron"
        case .wedge: return "Wedge"
        }
    }
}
