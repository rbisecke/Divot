import Foundation

// Club-aware benchmarks + fault evaluation (inlined from config/benchmarks.json for type safety).

enum Direction { case max, min }

struct MetricDef {
    let key, label, faultCode, cue, drill: String
    let direction: Direction
    var good: Double      // good_max (max) or good_min (min)
    var fault: Double     // fault_max (max) or fault_min (min)
    let angles: [Angle]?  // nil = any
}

enum Benchmarks {
    static let defaults: [MetricDef] = [
        MetricDef(key: "head_sway_in", label: "Lateral head sway", faultCode: "head_sway",
                  cue: "keep your nose over the ball — turn, don't slide", drill: "D3", direction: .max, good: 2, fault: 4, angles: [.faceOn]),
        MetricDef(key: "head_rise_cm", label: "Head rise to impact (early extension)", faultCode: "early_extension",
                  cue: "chest points at the board past the ball", drill: "D11", direction: .max, good: 2, fault: 3.5, angles: [.faceOn, .dtl]),
        MetricDef(key: "spine_loss_deg", label: "Spine-angle lost by impact", faultCode: "loss_of_posture",
                  cue: "stay in your tilt — belt buckle down through the ball", drill: "D11", direction: .max, good: 5, fault: 8, angles: [.dtl, .faceOn]),
        MetricDef(key: "pelvis_sway_in", label: "Pelvis lateral sway", faultCode: "hip_slide",
                  cue: "rotate the belt buckle to the target, don't slide it", drill: "D4", direction: .max, good: 3, fault: 4, angles: [.faceOn]),
        MetricDef(key: "weight_lead_pct_est", label: "Weight on lead foot at impact (estimated)", faultCode: "hanging_back",
                  cue: "finish balanced on your front foot", drill: "D3", direction: .min, good: 80, fault: 70, angles: [.faceOn]),
        MetricDef(key: "tempo_ratio", label: "Tempo (backswing:downswing)", faultCode: "slow_transition",
                  cue: "smooth back, then commit down — 3 counts back, 1 through", drill: "D12", direction: .max, good: 3.4, fault: 4, angles: nil),
        MetricDef(key: "xfactor_deg", label: "X-factor (shoulder-hip separation at top)", faultCode: "low_separation",
                  cue: "turn your shoulders fully while the hips resist", drill: "D10", direction: .min, good: 40, fault: 30, angles: [.faceOn, .dtl]),
        MetricDef(key: "lead_arm_bend_deg", label: "Lead-arm bend after impact", faultCode: "chicken_wing",
                  cue: "extend both arms toward the target through impact", drill: "D8", direction: .max, good: 15, fault: 20, angles: [.faceOn, .dtl]),
        MetricDef(key: "trail_knee_flex_loss_deg", label: "Trail-knee flex lost in backswing", faultCode: "trail_leg_straighten",
                  cue: "keep the flex in your trail knee as you turn back", drill: "D6", direction: .max, good: 10, fault: 15, angles: [.dtl]),
    ]
    // Per-club overrides (good, fault) by metric key.
    static let overrides: [ClubCategory: [String: (Double, Double)]] = [
        .driver: ["weight_lead_pct_est": (60, 50), "head_rise_cm": (4, 6)],
        .wood:   ["weight_lead_pct_est": (65, 55), "head_rise_cm": (3, 4.5)],
        .wedge:  ["weight_lead_pct_est": (85, 75)],
    ]
}

/// Public, UI-facing description of a metric's benchmark (so the app can show
/// "your value vs the target" with the right club-aware thresholds).
public struct MetricInfo: Sendable, Identifiable {
    public var id: String { key }
    public let key, label, faultCode, cue, drill: String
    public let higherIsBetter: Bool   // true when the metric should be small (a max cap) is false; see below
    public let good, fault: Double
    public let angles: [Angle]?
}

public enum FaultEvaluator {
    /// Club-aware benchmark table for display (thresholds already resolved for the category).
    public static func benchmarks(category: ClubCategory) -> [MetricInfo] {
        let ov = Benchmarks.overrides[category.analysisFamily] ?? [:]
        return Benchmarks.defaults.map { def in
            let g = ov[def.key]?.0 ?? def.good
            let f = ov[def.key]?.1 ?? def.fault
            // direction .min means "bigger is better" (e.g. weight on lead foot, x-factor).
            return MetricInfo(key: def.key, label: def.label, faultCode: def.faultCode, cue: def.cue, drill: def.drill,
                              higherIsBetter: def.direction == .min, good: g, fault: f, angles: def.angles)
        }
    }

    public static func evaluate(_ metrics: SwingMetrics, category: ClubCategory, angle: Angle) -> [Fault] {
        let ov = Benchmarks.overrides[category.analysisFamily] ?? [:]
        var out: [Fault] = []
        for var def in Benchmarks.defaults {
            if let angles = def.angles, !angles.contains(angle) { continue }
            guard let v = metrics[def.key] else { continue }
            if let (g, f) = ov[def.key] { def.good = g; def.fault = f }
            var fired = false, sev = 0.0
            switch def.direction {
            case .max: if v > def.fault { fired = true; sev = min(1, (v - def.good) / max(def.fault - def.good, 0.1)) }
            case .min: if v < def.fault { fired = true; sev = min(1, (def.good - v) / max(def.good - def.fault, 0.1)) }
            }
            if fired {
                out.append(Fault(code: def.faultCode, label: def.label, metric: def.key,
                                 value: v, threshold: def.fault, severity: (sev*10).rounded()/10,
                                 cue: def.cue, drill: def.drill))
            }
        }
        return out.sorted { $0.severity > $1.severity }
    }
}

// MARK: - Segmenter (pose-based swing detection for multi-swing clips)

public struct ClipWindow: Sendable { public var start: Double, end: Double, impact: Double }

public enum Segmenter {
    /// Find up to `max` swings as prominent, well-separated lead-hand speed peaks.
    public static func swings(in pose: PoseSequence, max maxN: Int = 5, hand: Hand = .right,
                              minSep: Double = 3.0, preRoll: Double = 2.0, postRoll: Double = 2.2) -> [ClipWindow] {
        let s = JointSeries(pose); let n = s.n
        guard n > 4 else { return [] }
        let lead: Joint = hand == .left ? .rightWrist : .leftWrist
        let lwx = s.jx(lead), lwy = s.jy(lead)
        var speed = [Double](repeating: 0, count: n)
        for i in 1..<n { let dx = (lwx[i]-lwx[i-1])*s.w, dy = (lwy[i]-lwy[i-1])*s.h; speed[i] = (dx*dx+dy*dy).squareRoot() }
        speed = JointSeries.smooth(speed, 2)
        let w = Swift.max(1, Int(0.4 * pose.fps))
        var cands: [(t: Double, v: Double)] = []
        for i in 0..<n {
            var isMax = true
            for k in Swift.max(0,i-w)...Swift.min(n-1,i+w) where speed[k] > speed[i] { isMax = false; break }
            if isMax && speed[i] > 0 { cands.append((s.times[i], speed[i])) }
        }
        cands.sort { $0.v > $1.v }
        var picked: [Double] = []
        for c in cands { if picked.allSatisfy({ abs($0 - c.t) >= minSep }) { picked.append(c.t) }; if picked.count >= maxN { break } }
        picked.sort()
        let dur = s.times.last ?? 0
        return picked.map { ClipWindow(start: Swift.max(0, $0 - preRoll), end: Swift.min(dur, $0 + postRoll), impact: $0) }
    }
}
