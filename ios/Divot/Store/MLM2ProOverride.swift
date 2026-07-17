// Part of Divot (built + tested; see App/DivotApp.swift).
import Foundation
import SwiftData
import SwingCore

/// A learned mapping from an MLM2PRO "Club Type" code (e.g. "sw") to a specific bag club,
/// recorded when the user confirms an ambiguous/unknown code so future imports don't re-ask.
@Model
final class MLM2ProOverride {
    var code: String = ""
    var clubID: UUID = UUID()
    init(code: String, clubID: UUID) { self.code = code; self.clubID = clubID }
}

enum OverrideStore {
    static func all(_ context: ModelContext) -> [String: UUID] {
        let rows = (try? context.fetch(FetchDescriptor<MLM2ProOverride>())) ?? []
        return Dictionary(rows.map { ($0.code, $0.clubID) }, uniquingKeysWith: { _, b in b })
    }

    /// Throws rather than swallowing a persistence failure (Medium finding: the UI would show
    /// the override as confirmed even when the write to disk failed).
    static func set(code: String, clubID: UUID, in context: ModelContext) throws {
        if let existing = try context.fetch(FetchDescriptor<MLM2ProOverride>()).first(where: { $0.code == code }) {
            existing.clubID = clubID
        } else {
            context.insert(MLM2ProOverride(code: code, clubID: clubID))
        }
        try context.save()
    }
}

/// Resolves the distinct club codes in a CSV against the bag + learned overrides. Pure, so the
/// auto-bind / needs-confirm split is unit-testable.
enum ClubCodeResolver {
    struct Resolution: Identifiable {
        let code: String
        let match: MLM2ProClub.Match
        var id: String { code }
    }

    /// One resolution per distinct (case-insensitive) code, in first-seen order.
    static func resolve(rows: [ShotRow], bag: [ClubSpec], overrides: [String: UUID]) -> [Resolution] {
        var seen = Set<String>()
        var out: [Resolution] = []
        for r in rows {
            let code = r.clubType.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = code.lowercased()
            guard !code.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(Resolution(code: code, match: MLM2ProClub.map(code: code, bag: bag, overrides: overrides)))
        }
        return out
    }

    /// Codes that need a one-time confirmation (ambiguous or unknown).
    static func needsConfirm(_ res: [Resolution]) -> [String] {
        res.compactMap { if case .matched = $0.match { return nil } else { return $0.code } }
    }

    /// code → resolved club for the auto-bound (matched) codes.
    static func bindings(_ res: [Resolution]) -> [String: ClubSpec] {
        var m: [String: ClubSpec] = [:]
        for r in res { if case .matched(let c) = r.match { m[r.code] = c } }
        return m
    }
}
