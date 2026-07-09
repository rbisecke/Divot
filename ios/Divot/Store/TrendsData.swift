// Part of Divot (built + tested; see App/DivotApp.swift).
import Foundation
import SwingCore

/// Prepares saved sessions for the Trends screen. Each session's club is replaced by the
/// SavedSession snapshot (which carries the stable clubID), so per-club grouping is correct
/// even for migrated legacy sessions whose encoded analysis predates ClubSpec.
enum TrendsData {
    static func sessions(_ saved: [SavedSession]) -> [Session] {
        saved.compactMap { s in
            guard var sess = s.session else { return nil }
            sess.club = s.club
            return sess
        }
    }
}
