// Part of Divot (built + tested; see App/DivotApp.swift).
import Foundation
import SwiftData

/// P2.7 — optional MLM2PRO launch-monitor numbers attached to a saved swing.
/// Linked by the SavedSession's id (no formal relationship, to stay fully optional).
/// Every field is optional; the app is completely usable without any ShotData.
@Model
final class ShotData {
    var sessionID: UUID
    /// Which swing in the session this shot belongs to (nil = session-level / manual entry).
    var swingIndex: Int?
    /// The bag club this shot's CSV "Club Type" resolved to (nil = unmatched / manual entry).
    var clubID: UUID?
    var ballSpeedMph: Double?
    var clubSpeedMph: Double?
    var carryYds: Double?
    var totalYds: Double?
    var spinRpm: Double?
    var launchDeg: Double?
    var sideDeg: Double?
    var smashFactor: Double?

    init(sessionID: UUID, swingIndex: Int? = nil, clubID: UUID? = nil,
         ballSpeedMph: Double? = nil, clubSpeedMph: Double? = nil,
         carryYds: Double? = nil, totalYds: Double? = nil, spinRpm: Double? = nil,
         launchDeg: Double? = nil, sideDeg: Double? = nil, smashFactor: Double? = nil) {
        self.sessionID = sessionID
        self.swingIndex = swingIndex
        self.clubID = clubID
        self.ballSpeedMph = ballSpeedMph; self.clubSpeedMph = clubSpeedMph
        self.carryYds = carryYds; self.totalYds = totalYds; self.spinRpm = spinRpm
        self.launchDeg = launchDeg; self.sideDeg = sideDeg; self.smashFactor = smashFactor
    }

    /// Ordered (label, value) rows for display, skipping unset fields.
    var displayRows: [(String, String)] {
        var out: [(String, String)] = []
        func add(_ label: String, _ v: Double?, _ unit: String) {
            if let v { out.append((label, String(format: "%.1f%@", v, unit))) }
        }
        add("Ball speed", ballSpeedMph, " mph"); add("Club speed", clubSpeedMph, " mph")
        add("Carry", carryYds, " yd"); add("Total", totalYds, " yd")
        add("Spin", spinRpm, " rpm"); add("Launch", launchDeg, "°")
        add("Side", sideDeg, "°"); add("Smash", smashFactor, "")
        return out
    }
}
