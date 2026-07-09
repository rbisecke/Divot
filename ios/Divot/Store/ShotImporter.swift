// Part of Divot (built + tested; see App/DivotApp.swift).
import Foundation
import SwingCore

/// P3.1 — map parsed MLM2PRO CSV rows onto a session's swings, by order.
/// Pure + Simulator-safe (no Vision), so it's fully unit-testable.
enum ShotImporter {
    /// Row i attaches to swing i, up to the smaller of the two counts. When a bag (+ learned
    /// overrides) is supplied, each row's "Club Type" is resolved to a bag club and its id
    /// recorded on the shot (nil when the code is ambiguous/unknown and unconfirmed).
    static func match(rows: [ShotRow], to session: Session,
                      bag: [ClubSpec] = [], overrides: [String: UUID] = [:]) -> [ShotData] {
        let n = min(rows.count, session.swings.count)
        guard n > 0 else { return [] }
        return (0..<n).map { i in
            let r = rows[i]
            let sw = session.swings[i]
            var clubID: UUID?
            if !bag.isEmpty, case .matched(let club) = MLM2ProClub.map(code: r.clubType, bag: bag, overrides: overrides) {
                clubID = club.id
            }
            return ShotData(sessionID: session.id, swingIndex: sw.index, clubID: clubID,
                            ballSpeedMph: r.ballSpeed, clubSpeedMph: r.clubSpeed,
                            carryYds: r.carryDistance, totalYds: r.totalDistance, spinRpm: r.spinRate,
                            launchDeg: r.launchAngle, sideDeg: r.sideCarry, smashFactor: r.smashFactor)
        }
    }
}
