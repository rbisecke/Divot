// Part of Divot (built + tested; see App/DivotApp.swift).
import Foundation

/// P2.6 — maps each drill code used by the engine's faults to a demo-clip asset + title.
/// The actual demo videos are user-supplied content dropped into
/// Divot/DrillClips/<file>; this catalog guarantees every fault has an entry.
enum DrillCatalog {
    struct Drill { let code: String; let title: String; let asset: String }

    static let all: [String: Drill] = [
        "D3":  Drill(code: "D3",  title: "Weight-forward strike",      asset: "drill_d3.mp4"),
        "D4":  Drill(code: "D4",  title: "Hip rotation, no slide",     asset: "drill_d4.mp4"),
        "D6":  Drill(code: "D6",  title: "Trail-knee flex hold",       asset: "drill_d6.mp4"),
        "D8":  Drill(code: "D8",  title: "Full extension (no chicken wing)", asset: "drill_d8.mp4"),
        "D10": Drill(code: "D10", title: "Shoulder-hip separation",    asset: "drill_d10.mp4"),
        "D11": Drill(code: "D11", title: "Stay in posture",            asset: "drill_d11.mp4"),
        "D12": Drill(code: "D12", title: "3:1 tempo",                  asset: "drill_d12.mp4"),
    ]

    static func drill(for code: String) -> Drill? { all[code] }

    /// URL of a bundled demo clip if the content has been added, else nil (mapping still valid).
    static func clipURL(for code: String) -> URL? {
        guard let d = all[code] else { return nil }
        let name = (d.asset as NSString).deletingPathExtension
        let ext = (d.asset as NSString).pathExtension
        return Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "DrillClips")
            ?? Bundle.main.url(forResource: name, withExtension: ext)
    }
}
