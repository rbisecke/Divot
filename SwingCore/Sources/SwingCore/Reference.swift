import Foundation
import CoreGraphics

// Stages ⑧⑨⑩ — normalized templates, bundled pro reference library, and pose comparison.
// Ported from the CLI buildref.swift (normalization) + ghost.swift (phase interpolation).

// MARK: - Template builder

public enum TemplateBuilder {
    static let templateJoints: [Joint] = [.nose, .neck, .leftShoulder, .rightShoulder, .leftElbow, .rightElbow,
                                          .leftWrist, .rightWrist, .leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle]

    /// Normalize pose at each phase: origin = hip-midpoint, scale = shoulder width (=1).
    /// Body-size/position independent, so any two swings become directly comparable.
    public static func build(_ pose: PoseSequence, events: SwingEvents, category: ClubCategory, angle: Angle,
                             metrics: SwingMetrics = SwingMetrics(), source: String = "me") -> Template {
        let phaseFrame: [(Phase, Int)] = [(.address, events.address.frame), (.top, events.top.frame),
                                          (.impact, events.impact.frame), (.finish, events.finish.frame)]
        var phases: [Phase: [Joint: CGPoint]] = [:]
        for (phase, fi) in phaseFrame { phases[phase] = normalized(pose, fi) }
        return Template(club: category.referenceDir, view: angle.rawValue, source: source, phases: phases, metrics: metrics)
    }

    static func normalized(_ pose: PoseSequence, _ fi: Int) -> [Joint: CGPoint] {
        guard fi >= 0, fi < pose.frames.count else { return [:] }
        let pts = pose.frames[fi].joints
        guard let lh = pts[.leftHip], let rh = pts[.rightHip], let ls = pts[.leftShoulder], let rs = pts[.rightShoulder] else { return [:] }
        let ox = (lh.x + rh.x) / 2, oy = (lh.y + rh.y) / 2
        let sw = max(0.02, (((ls.x-rs.x)*(ls.x-rs.x) + (ls.y-rs.y)*(ls.y-rs.y)).squareRoot()))
        var out: [Joint: CGPoint] = [:]
        for j in templateJoints { if let p = pts[j] { out[j] = CGPoint(x: (p.x-ox)/sw, y: (p.y-oy)/sw) } }
        return out
    }
}

// MARK: - Reference store (bundled pro templates)

public enum ReferenceStore {
    // Reference JSON uses String-keyed phases/joints, so decode via an intermediate then map.
    private struct RefPoint: Decodable { let x: Double; let y: Double }
    private struct RefModel: Decodable {
        let club: String, view: String, source: String
        let phases: [String: [String: RefPoint]]
        let metrics: [String: Double?]?   // some slots have null (NaN-sanitized) metric values
    }

    /// Load the bundled pro template for a club category + angle (nil if the slot is missing).
    public static func template(category: ClubCategory, angle: Angle) -> Template? {
        let dir = "\(category.referenceDir)_\(angle.rawValue)"
        guard let url = resourceURL(dir: dir) ?? Bundle.module.url(forResource: "model", withExtension: "json", subdirectory: "reference/\(dir)"),
              let data = try? Data(contentsOf: url),
              let ref = try? JSONDecoder().decode(RefModel.self, from: data) else { return nil }
        var phases: [Phase: [Joint: CGPoint]] = [:]
        for (pk, joints) in ref.phases {
            guard let phase = Phase(rawValue: pk) else { continue }
            var jm: [Joint: CGPoint] = [:]
            for (jk, pt) in joints { if let j = Joint(rawValue: jk) { jm[j] = CGPoint(x: pt.x, y: pt.y) } }
            phases[phase] = jm
        }
        var m = SwingMetrics()
        if let rm = ref.metrics {
            var compact: [String: Double] = [:]
            for (k, v) in rm { if let v = v { compact[k] = v } }
            m.applyDict(compact)
        }
        return Template(club: ref.club, view: ref.view, source: ref.source, phases: phases, metrics: m)
    }

    private static func resourceURL(dir: String) -> URL? {
        Bundle.module.url(forResource: "model", withExtension: "json", subdirectory: "reference/\(dir)")
    }

    /// All (category, angle) slots that have a bundled template.
    public static var available: [(ClubCategory, Angle)] {
        var out: [(ClubCategory, Angle)] = []
        let cats: [ClubCategory] = [.driver, .wood, .iron, .wedge]
        for c in cats { for a in [Angle.faceOn, .dtl] where template(category: c, angle: a) != nil { out.append((c, a)) } }
        return out
    }
}

// MARK: - Comparator

public enum PoseComparator {
    /// Compare a user template to a reference (pro) template.
    /// Per-phase match = 1/(1+mean joint distance) in shoulder-width units → self-compare = 1.0.
    /// `deltas` = user metric − club-aware "good" target (how far each metric is from ideal).
    public static func compare(user: Template, reference: Template, category: ClubCategory, angle: Angle) -> Comparison {
        var perPhase: [Phase: Double] = [:]
        for phase in Phase.allCases {
            guard let up = user.phases[phase], let rp = reference.phases[phase] else { continue }
            var sum = 0.0, count = 0
            for (j, u) in up {
                guard let r = rp[j] else { continue }
                sum += (((u.x-r.x)*(u.x-r.x) + (u.y-r.y)*(u.y-r.y)).squareRoot()); count += 1
            }
            if count > 0 { perPhase[phase] = (100 * 1.0 / (1.0 + sum/Double(count))).rounded() / 100 }
        }
        let overall = perPhase.isEmpty ? 0 : (100 * perPhase.values.reduce(0,+) / Double(perPhase.count)).rounded() / 100

        var deltas: [String: Double] = [:]
        let ov = Benchmarks.overrides[category.analysisFamily] ?? [:]
        for def in Benchmarks.defaults {
            if let angles = def.angles, !angles.contains(angle) { continue }
            guard let v = user.metrics[def.key] else { continue }
            let good = ov[def.key]?.0 ?? def.good
            deltas[def.key] = ((v - good) * 10).rounded() / 10
        }
        return Comparison(deltas: deltas, perPhaseMatch: perPhase, overall: overall)
    }
}

extension SwingMetrics {
    mutating func applyDict(_ d: [String: Double]) {
        headSwayIn = d["head_sway_in"]; headRiseCm = d["head_rise_cm"]; spineLossDeg = d["spine_loss_deg"]
        pelvisSwayIn = d["pelvis_sway_in"]; weightLeadPctEst = d["weight_lead_pct_est"]; tempoRatio = d["tempo_ratio"]
        xfactorDeg = d["xfactor_deg"]; leadArmBendDeg = d["lead_arm_bend_deg"]; trailKneeFlexLossDeg = d["trail_knee_flex_loss_deg"]
    }
}
