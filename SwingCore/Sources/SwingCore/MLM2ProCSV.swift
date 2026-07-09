import Foundation

// Stage P3.1 — parse a Rapsodo MLM2PRO shot-export CSV into typed rows.
// Deterministic and pure: quoted fields, blank cells → nil, malformed lines skipped.

public struct ShotRow: Codable, Sendable {
    public var clubType: String
    public var clubBrand: String?
    public var clubModel: String?
    public var carryDistance: Double?
    public var totalDistance: Double?
    public var ballSpeed: Double?
    public var launchAngle: Double?
    public var launchDirection: Double?
    public var apex: Double?
    public var sideCarry: Double?
    public var clubSpeed: Double?
    public var smashFactor: Double?
    public var descentAngle: Double?
    public var attackAngle: Double?
    public var clubPath: Double?
    public var spinRate: Double?
    public var spinAxis: Double?
}

public enum MLM2ProCSV {

    /// Parse the export text. The first non-empty line is treated as the header;
    /// columns are matched by (normalized) header name, so column order/extra columns are tolerated.
    public static func parse(_ text: String) -> [ShotRow] {
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return [] }

        let header = fields(lines[0]).map { normalize($0) }
        func index(_ name: String) -> Int? { header.firstIndex(of: normalize(name)) }

        // Column indices (nil if a column is absent in this export variant).
        let iClub = index("Club Type")
        let iBrand = index("Club Brand"), iModel = index("Club Model")
        let iCarry = index("Carry Distance"), iTotal = index("Total Distance")
        let iBall = index("Ball Speed"), iLaunchA = index("Launch Angle"), iLaunchD = index("Launch Direction")
        let iApex = index("Apex"), iSide = index("Side Carry"), iClubSpd = index("Club Speed")
        let iSmash = index("Smash Factor"), iDescent = index("Descent Angle"), iAttack = index("Attack Angle")
        let iPath = index("Club Path"), iSpin = index("Spin Rate"), iAxis = index("Spin Axis")

        var rows: [ShotRow] = []
        for line in lines.dropFirst() {
            let f = fields(line)
            // A row needs at least a club type to be meaningful; skip malformed/short lines.
            guard let ci = iClub, ci < f.count else { continue }
            let club = str(f, ci)
            guard let clubType = club, !clubType.isEmpty else { continue }
            rows.append(ShotRow(
                clubType: clubType,
                clubBrand: str(f, iBrand), clubModel: str(f, iModel),
                carryDistance: dbl(f, iCarry), totalDistance: dbl(f, iTotal),
                ballSpeed: dbl(f, iBall), launchAngle: dbl(f, iLaunchA), launchDirection: dbl(f, iLaunchD),
                apex: dbl(f, iApex), sideCarry: dbl(f, iSide), clubSpeed: dbl(f, iClubSpd),
                smashFactor: dbl(f, iSmash), descentAngle: dbl(f, iDescent), attackAngle: dbl(f, iAttack),
                clubPath: dbl(f, iPath), spinRate: dbl(f, iSpin), spinAxis: dbl(f, iAxis)
            ))
        }
        return rows
    }

    // MARK: - helpers

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Value at a column index, or nil if the column is absent, out of range, or blank.
    private static func str(_ fields: [String], _ i: Int?) -> String? {
        guard let i = i, i >= 0, i < fields.count else { return nil }
        let v = fields[i].trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    private static func dbl(_ fields: [String], _ i: Int?) -> Double? {
        guard let s = str(fields, i) else { return nil }
        return Double(s)
    }

    /// Split one CSV line into fields, honoring double-quoted values and escaped quotes ("").
    private static func fields(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuotes = false
        let chars = Array(line)
        var k = 0
        while k < chars.count {
            let c = chars[k]
            if inQuotes {
                if c == "\"" {
                    if k + 1 < chars.count && chars[k + 1] == "\"" { cur.append("\""); k += 1 }
                    else { inQuotes = false }
                } else { cur.append(c) }
            } else {
                if c == "\"" { inQuotes = true }
                else if c == "," { out.append(cur); cur = "" }
                else { cur.append(c) }
            }
            k += 1
        }
        out.append(cur)
        return out
    }
}
