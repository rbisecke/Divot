import Foundation

// Club model (S1) — replaces the fixed `Club` enum with an open struct so users can
// build an arbitrary bag (any number of wedges by loft, hybrids, driving irons, etc.).
// Analysis stays *category-based*: new categories fold onto the four benchmark/reference
// families via `analysisFamily`, so the engine math and bundled data are untouched.

/// Club categories used for benchmarks + reference-model selection.
/// hybrid/drivingIron are display-only sub-types that reuse an existing analysis family.
public enum ClubCategory: String, Codable, CaseIterable, Sendable {
    case driver, wood, hybrid
    case drivingIron = "driving-iron"
    case iron, wedge

    /// Fold a display category onto the family that owns its benchmark/reference data.
    public var analysisFamily: ClubCategory {
        switch self {
        case .hybrid: return .wood
        case .drivingIron: return .iron
        default: return self
        }
    }

    /// On-disk reference/benchmark family dir (irons use the legacy "mid-iron" slot name).
    var referenceDir: String {
        switch analysisFamily {
        case .driver: return "driver"
        case .wood:   return "wood"
        case .wedge:  return "wedge"
        default:      return "mid-iron"   // iron family
        }
    }
}

/// One club in the bag. `id` gives a stable identity so history/trends survive renames
/// and re-lofts. `number` for woods/hybrids/irons; `loft` required for wedges (source of
/// truth), optional elsewhere; `label` is a display override ("PW", "3W", a nickname).
public struct ClubSpec: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var category: ClubCategory
    public var number: Int?
    public var loft: Double?
    public var label: String?

    public init(id: UUID = UUID(), category: ClubCategory, number: Int? = nil,
                loft: Double? = nil, label: String? = nil) {
        self.id = id; self.category = category; self.number = number
        self.loft = loft; self.label = label
    }

    enum CodingKeys: String, CodingKey { case id, category, number, loft, label }

    /// Tolerant decode: accept the current object form, or a legacy bare-string enum raw
    /// value ("7i", "pw", …) from pre-ClubSpec persisted Sessions, mapped via ClubLegacy.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let raw = try? single.decode(String.self) {
            self = ClubLegacy.map(rawValue: raw); return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        category = try c.decode(ClubCategory.self, forKey: .category)
        number = try c.decodeIfPresent(Int.self, forKey: .number)
        loft = try c.decodeIfPresent(Double.self, forKey: .loft)
        label = try c.decodeIfPresent(String.self, forKey: .label)
    }

    /// Human label: the explicit label if set, else derived from category + number/loft.
    public var displayName: String {
        if let label = label, !label.isEmpty { return label }
        switch category {
        case .driver: return "Driver"
        case .wood:   return number.map { "\($0)W" } ?? "Wood"
        case .hybrid: return number.map { "\($0)H" } ?? "Hybrid"
        case .iron:   return number.map { "\($0)i" } ?? "Iron"
        case .drivingIron: return number.map { "\($0)i" } ?? "Driving Iron"
        case .wedge:
            if let loft = loft { return "\(Int(loft.rounded()))°" }
            return "Wedge"
        }
    }

    /// Ordering key: family-major (Driver→woods→hybrids→driving irons→irons→wedges),
    /// then ascending by loft when present else club number. Approximates loft order.
    public var sortKey: Double {
        let rank: Double
        switch category {
        case .driver:      rank = 0
        case .wood:        rank = 1
        case .hybrid:      rank = 2
        case .drivingIron: rank = 3
        case .iron:        rank = 4
        case .wedge:       rank = 5
        }
        let tie = loft ?? Double(number ?? 0)
        return rank * 1000 + tie
    }
}

/// Bag construction + wedge-labelling helpers. Pure, engine-side so they can be unit-tested.
public enum Bag {
    /// Seed bag for a new install: Driver, 3W, 5H, 6–9i, PW(46), 50, 54, 58.
    public static var defaultBag: [ClubSpec] {
        [
            ClubSpec(category: .driver),
            ClubSpec(category: .wood, number: 3),
            ClubSpec(category: .hybrid, number: 5),
            ClubSpec(category: .iron, number: 6),
            ClubSpec(category: .iron, number: 7),
            ClubSpec(category: .iron, number: 8),
            ClubSpec(category: .iron, number: 9),
            ClubSpec(category: .wedge, loft: 46, label: "PW"),
            ClubSpec(category: .wedge, loft: 50),
            ClubSpec(category: .wedge, loft: 54),
            ClubSpec(category: .wedge, loft: 58),
        ]
    }

    /// Bag order for pickers/trends: family-major, then loft/number ascending.
    public static func sorted(_ clubs: [ClubSpec]) -> [ClubSpec] {
        clubs.sorted { $0.sortKey < $1.sortKey }
    }

    /// Prefill loft when a wedge is added by common name/letter (PW46/GW50/SW56/LW60).
    public static func wedgePrefillLoft(name: String) -> Double {
        let n = name.lowercased()
        if n.contains("lob") || n == "lw" { return 60 }
        if n.contains("sand") || n == "sw" { return 56 }
        if n.contains("gap") || n.contains("approach") || n == "gw" || n == "aw" { return 50 }
        return 46   // pitching / PW / default
    }

    /// Suggested letter label for a wedge of a given loft.
    public static func suggestedWedgeLabel(loft: Double) -> String {
        switch loft {
        case ..<48.5: return "PW"
        case ..<52.5: return "GW"
        case ..<57.5: return "SW"
        default:      return "LW"
        }
    }
}

/// Map an MLM2PRO "Club Type" code onto a club in the user's bag.
/// Codes are name/letter-based (never a loft): irons `<n>i`, hybrids `<n>h`, woods `<n>w`,
/// driver `d…`, wedges `pw/gw/sw/lw` (or full "pitching/gap/sand/lob wedge"). Wedge codes
/// are lossy (a name covers a loft range), so a code matching >1 bag wedge is `ambiguous`.
public enum MLM2ProClub {
    public enum Match: Equatable { case matched(ClubSpec), ambiguous([ClubSpec]), unknown }

    // Wedge name/letter → candidate loft set (which physical loft the name might mean).
    private static let wedgeLoftSets: [(keys: [String], lofts: Set<Int>)] = [
        (["pw", "pitching wedge", "pitching"], [44, 45, 46, 47, 48]),
        (["gw", "aw", "gap wedge", "approach wedge", "gap", "approach"], [50, 52]),
        (["sw", "sand wedge", "sand"], [54, 56]),
        (["lw", "lob wedge", "lob"], [58, 60]),
    ]

    public static func map(code: String, bag: [ClubSpec], overrides: [String: UUID] = [:]) -> Match {
        let raw = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = raw.lowercased()

        // A learned override wins outright when it still points at a bag club.
        if let id = overrides[raw] ?? overrides[key], let club = bag.first(where: { $0.id == id }) {
            return .matched(club)
        }

        // <n>i iron, <n>h hybrid, <n>w wood.
        if let (n, suffix) = numberSuffix(key) {
            switch suffix {
            case "i": return matchNumbered(bag, family: [.iron, .drivingIron], number: n)
            case "h": return matchNumbered(bag, family: [.hybrid], number: n)
            case "w": return matchNumbered(bag, family: [.wood], number: n)
            default: break
            }
        }

        // driver: "d", "dr", "driver".
        if key == "d" || key == "dr" || key.hasPrefix("driver") {
            if let d = bag.first(where: { $0.category == .driver }) { return .matched(d) }
            return .unknown
        }

        // wedges by name/letter → loft candidate set → the bag wedge(s) in range.
        if let lofts = wedgeLoftSets.first(where: { set in set.keys.contains(where: { key == $0 || key.contains($0) }) })?.lofts {
            let inRange = bag.filter { $0.category == .wedge && ($0.loft.map { lofts.contains(Int($0.rounded())) } ?? false) }
            if inRange.count == 1 { return .matched(inRange[0]) }
            if inRange.count > 1 { return .ambiguous(Bag.sorted(inRange)) }
            return .unknown
        }

        return .unknown
    }

    /// Best-effort loft parse from a free-text club model string (trailing number, e.g. "RTX 54").
    public static func loft(fromModel model: String) -> Double? {
        let scanner = model.reversed()
        var digits = ""
        for ch in scanner {
            if ch.isNumber { digits.insert(ch, at: digits.startIndex) }
            else if !digits.isEmpty { break }
            else if ch == "." || ch == "°" || ch == " " { continue }
            else { break }
        }
        guard let v = Double(digits), v >= 40, v <= 72 else { return nil }
        return v
    }

    private static func matchNumbered(_ bag: [ClubSpec], family: [ClubCategory], number: Int) -> Match {
        if let c = bag.first(where: { family.contains($0.category) && $0.number == number }) { return .matched(c) }
        return .unknown
    }

    /// Split a code like "9i" → (9, "i"); returns nil when it isn't <digits><letter>.
    private static func numberSuffix(_ s: String) -> (Int, String)? {
        guard let last = s.last, last.isLetter else { return nil }
        let digits = String(s.dropLast())
        guard !digits.isEmpty, let n = Int(digits) else { return nil }
        return (n, String(last))
    }
}

/// One-time migration of the old fixed-enum raw values onto ClubSpec (used by the app on
/// first launch of the new version). Every legacy `Club` raw value maps here.
public enum ClubLegacy {
    public static func map(rawValue: String) -> ClubSpec {
        switch rawValue.lowercased() {
        case "dr", "driver": return ClubSpec(category: .driver)
        case "pw":           return ClubSpec(category: .wedge, loft: 46, label: "PW")
        case "gw":           return ClubSpec(category: .wedge, loft: 50, label: "GW")
        case "aw":           return ClubSpec(category: .wedge, loft: 50, label: "AW")
        case "sw":           return ClubSpec(category: .wedge, loft: 56, label: "SW")
        case "lw":           return ClubSpec(category: .wedge, loft: 60, label: "LW")
        default:
            // "<n>w" wood, "<n>i" iron.
            if let last = rawValue.lowercased().last, let n = Int(rawValue.dropLast()) {
                if last == "w" { return ClubSpec(category: .wood, number: n) }
                if last == "i" { return ClubSpec(category: .iron, number: n) }
            }
            return ClubSpec(category: .iron, number: 7)   // safe fallback
        }
    }
}
