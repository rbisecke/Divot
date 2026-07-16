// Part of Divot (built + tested; see App/DivotApp.swift).
import Foundation
import SwiftData
import SwingCore

/// Pure-ish bag mutations (add / retire / restore / delete / reorder) plus the add-club
/// spec builders. Kept out of the View so the rules are unit-testable against a container.
enum BagEditor {

    /// Append a club to the end of the bag. Throws rather than swallowing a persistence
    /// failure (Medium finding: widespread `try? context.save()` let the UI show success even
    /// when the write to disk failed, with the loss only discovered on next launch).
    static func add(_ spec: ClubSpec, to context: ModelContext) throws {
        let maxOrder = try context.fetch(FetchDescriptor<BagClub>()).map(\.order).max() ?? -1
        context.insert(BagClub(spec: spec, order: maxOrder + 1))
        try context.save()
    }

    static func retire(_ club: BagClub, in context: ModelContext) throws {
        club.retired = true; try context.save()
    }

    static func restore(_ club: BagClub, in context: ModelContext) throws {
        club.retired = false; try context.save()
    }

    /// Permanently remove a club. Past sessions keep their own ClubSpec snapshot, so this
    /// doesn't erase history; it only drops the club from the bag.
    static func delete(_ club: BagClub, in context: ModelContext) throws {
        context.delete(club); try context.save()
    }

    /// Persist a new ordering (indices become `order`).
    static func reorder(_ clubs: [BagClub], in context: ModelContext) throws {
        for (i, c) in clubs.enumerated() { c.order = i }
        try context.save()
    }

    /// Build a wedge spec. A name (e.g. "Sand wedge") prefills the loft and suggests a letter
    /// label; an explicit loft suggests a label. A non-empty custom label always wins; passing
    /// an empty custom label with only a loft keeps the loft-only display ("54°").
    static func wedgeSpec(name: String? = nil, loft: Double? = nil, customLabel: String? = nil) -> ClubSpec {
        let resolvedLoft = loft ?? name.map { Bag.wedgePrefillLoft(name: $0) } ?? 46
        let custom = customLabel?.trimmingCharacters(in: .whitespaces)
        let label: String?
        if let custom, !custom.isEmpty {
            label = custom
        } else if name != nil {
            label = Bag.suggestedWedgeLabel(loft: resolvedLoft)   // adding by name → labelled
        } else {
            label = nil                                            // adding by loft → loft display
        }
        return ClubSpec(category: .wedge, loft: resolvedLoft, label: label)
    }

    /// Build a numbered (or driver) spec for the non-wedge categories.
    static func numberedSpec(category: ClubCategory, number: Int?, customLabel: String? = nil) -> ClubSpec {
        let custom = customLabel?.trimmingCharacters(in: .whitespaces)
        return ClubSpec(category: category, number: category == .driver ? nil : number,
                        label: (custom?.isEmpty == false) ? custom : nil)
    }
}
