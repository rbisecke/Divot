// Part of Divot (built + tested; see App/DivotApp.swift).
import Foundation
import SwiftData
import SwingCore

/// A club the user carries. Persisted so the bag (any number of wedges by loft, hybrids,
/// driving irons, …) survives launches; `id` is the stable identity History/Trends group by.
/// `retired` hides a club from active pickers while keeping its past sessions resolvable.
@Model
final class BagClub {
    var id: UUID = UUID()
    var categoryRaw: String = ClubCategory.iron.rawValue
    var number: Int?
    var loft: Double?
    var label: String?
    var order: Int = 0
    var retired: Bool = false

    init(id: UUID = UUID(), categoryRaw: String, number: Int? = nil, loft: Double? = nil,
         label: String? = nil, order: Int = 0, retired: Bool = false) {
        self.id = id
        self.categoryRaw = categoryRaw
        self.number = number
        self.loft = loft
        self.label = label
        self.order = order
        self.retired = retired
    }

    convenience init(spec: ClubSpec, order: Int) {
        self.init(id: spec.id, categoryRaw: spec.category.rawValue, number: spec.number,
                  loft: spec.loft, label: spec.label, order: order, retired: false)
    }

    var spec: ClubSpec {
        ClubSpec(id: id, category: ClubCategory(rawValue: categoryRaw) ?? .iron,
                 number: number, loft: loft, label: label)
    }
}
