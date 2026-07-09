// Part of Divot (built + tested; see App/DivotApp.swift).
import Foundation
import SwiftData
import SwingCore

/// Bag persistence: seed the default bag on first launch, expose the active (non-retired)
/// clubs in sorted order, and migrate pre-ClubSpec sessions onto stable club ids.
enum BagStore {

    /// Seed the default bag (Driver, 3W, 5H, 6–9i, PW/50/54/58) the first time the app runs
    /// with an empty bag. Idempotent: a non-empty bag is left untouched.
    static func seedDefaultBagIfEmpty(_ context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<BagClub>())) ?? 0
        guard count == 0 else { return }
        for (i, spec) in Bag.sorted(Bag.defaultBag).enumerated() {
            context.insert(BagClub(spec: spec, order: i))
        }
        try? context.save()
    }

    /// Active clubs (not retired), in bag order.
    static func activeBag(_ context: ModelContext) -> [ClubSpec] {
        let clubs = (try? context.fetch(FetchDescriptor<BagClub>())) ?? []
        return Bag.sorted(clubs.filter { !$0.retired }.map(\.spec))
    }

    /// One-time migration of pre-ClubSpec sessions: map the legacy `clubRaw` string onto a
    /// ClubSpec, bind it to a matching bag club (creating one if the legacy club isn't carried),
    /// and write the stable `clubID` + snapshot. Idempotent — a row with `clubRaw == nil` is
    /// already migrated (or was created new). Returns the number of rows migrated.
    @discardableResult
    static func migrateLegacySessions(_ context: ModelContext) -> Int {
        let sessions = (try? context.fetch(FetchDescriptor<SavedSession>())) ?? []
        var bag = (try? context.fetch(FetchDescriptor<BagClub>())) ?? []
        var migrated = 0
        for s in sessions {
            guard let raw = s.clubRaw, !raw.isEmpty else { continue }
            let spec = ClubLegacy.map(rawValue: raw)
            let club = bag.first { matches($0, spec) } ?? {
                let order = (bag.map(\.order).max() ?? -1) + 1
                let created = BagClub(spec: spec, order: order)
                context.insert(created)
                bag.append(created)
                return created
            }()
            s.clubID = club.id
            s.clubCategoryRaw = club.categoryRaw
            s.clubNumber = club.number
            s.clubLoft = club.loft
            s.clubLabel = club.label
            s.clubRaw = nil
            migrated += 1
        }
        if migrated > 0 { try? context.save() }
        return migrated
    }

    /// A bag club "is" a legacy spec when the family matches: wedges by loft, driver outright,
    /// everything else by number. Keeps legacy wedges binding to the seeded 50/54/58 slots.
    private static func matches(_ b: BagClub, _ s: ClubSpec) -> Bool {
        guard b.categoryRaw == s.category.rawValue else { return false }
        switch s.category {
        case .wedge:  return b.loft == s.loft
        case .driver: return true
        default:      return b.number == s.number
        }
    }

    /// Resolve the stored default-club setting (a club id, or a legacy raw on first upgrade)
    /// to a concrete club in `specs`, falling back to a mid-iron / the first club.
    static func resolveClub(setting: String, in specs: [ClubSpec]) -> ClubSpec? {
        if let uuid = UUID(uuidString: setting), let s = specs.first(where: { $0.id == uuid }) { return s }
        if !setting.isEmpty {
            let legacy = ClubLegacy.map(rawValue: setting)
            if let s = specs.first(where: { $0.category == legacy.category && $0.number == legacy.number && $0.loft == legacy.loft }) {
                return s
            }
        }
        return specs.first(where: { $0.category == .iron }) ?? specs.first
    }
}
