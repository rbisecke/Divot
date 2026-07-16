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

    /// Parse the export text. The first non-blank record is treated as the header;
    /// columns are matched by (normalized) header name, so column order/extra columns are tolerated.
    public static func parse(_ text: String) -> [ShotRow] {
        let recs = records(text).filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard recs.count >= 2 else { return [] }

        let header = recs[0].map { normalize($0) }
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
        for f in recs.dropFirst() {
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

    /// Split the whole CSV text into records of fields, honoring double-quoted values (with
    /// escaped `""`) and, critically, a newline *inside* a quoted field — which is legal CSV and
    /// must stay part of that field's value rather than ending the record early. Previously this
    /// tokenized line-by-line (`text.split` on raw `\n`/`\r\n`/`\r` up front, then a per-line
    /// `fields` splitter), so a quoted field containing an embedded newline got cut in two before
    /// the quote-aware splitter ever saw it, mis-splitting one logical row into extra bogus ones.
    /// Walking the entire text in a single quote-tracking pass fixes that: only an *unquoted*
    /// newline ends a record.
    private static func records(_ text: String) -> [[String]] {
        var out: [[String]] = []
        var row: [String] = []
        var cur = ""
        var inQuotes = false
        let chars = Array(text)
        var k = 0
        func endField() { row.append(cur); cur = "" }
        func endRow() { endField(); out.append(row); row = [] }
        while k < chars.count {
            let c = chars[k]
            if inQuotes {
                if c == "\"" {
                    if k + 1 < chars.count && chars[k + 1] == "\"" { cur.append("\""); k += 1 }
                    else { inQuotes = false }
                } else { cur.append(c) }
            } else {
                if c == "\"" { inQuotes = true }
                else if c == "," { endField() }
                else if c == "\r" {
                    if k + 1 < chars.count && chars[k + 1] == "\n" { k += 1 }
                    endRow()
                } else if c == "\n" { endRow() }
                else { cur.append(c) }
            }
            k += 1
        }
        // Final record, if the text didn't end on a newline.
        if !cur.isEmpty || !row.isEmpty { endRow() }
        return out
    }
}
