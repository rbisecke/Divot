// Part of Divot (built + tested; see App/DivotApp.swift).
import Foundation
import SwingCore

/// P1.3 — tempo ratio display.
enum TempoFormat {
    static func ratioText(_ ratio: Double?) -> String {
        guard let r = ratio, r.isFinite, r > 0 else { return "—" }
        return String(format: "%.1f : 1", r)
    }
}

/// P1.7 — remember-last preferences, backed by an injectable UserDefaults for testing.
struct Preferences {
    let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The remembered club, stored as a bag-club id (a legacy enum raw on first upgrade,
    /// resolved by `BagStore.resolveClub`). Empty until the user picks one.
    var clubRaw: String {
        get { defaults.string(forKey: SettingsKey.club) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: SettingsKey.club) }
    }
    var angleRaw: String {
        get { defaults.string(forKey: SettingsKey.angle) ?? Angle.faceOn.rawValue }
        nonmutating set { defaults.set(newValue, forKey: SettingsKey.angle) }
    }
    var handRaw: String {
        get { defaults.string(forKey: SettingsKey.hand) ?? Hand.right.rawValue }
        nonmutating set { defaults.set(newValue, forKey: SettingsKey.hand) }
    }
}

/// P1.6 — decide whether an auto-detected camera angle should override the current pick.
enum AngleSelection {
    /// Returns the angle to select + a user-facing note, or nil to keep the current selection.
    static func apply(detection: (angle: Angle, confidence: Double),
                      minConfidence: Double = 0.5) -> (angle: Angle, note: String)? {
        guard detection.confidence >= minConfidence else { return nil }
        return (detection.angle, "Detected: \(detection.angle.label) — tap to change")
    }
}
