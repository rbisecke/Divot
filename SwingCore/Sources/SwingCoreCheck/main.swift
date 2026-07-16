import Foundation
import CoreGraphics
import SwingCore

// Headless validation harness (no XCTest needed — runs with Command Line Tools).
// Add checks per stage; exits non-zero on any failure so it gates commits.

var failures = 0
var total = 0
var skippedSections: [String] = []
func check(_ cond: Bool, _ msg: String) {
    total += 1
    if cond { print("  ✓ \(msg)") } else { print("  ✗ FAIL: \(msg)"); failures += 1 }
}
func approx(_ a: Double?, _ b: Double, _ tol: Double, _ msg: String) {
    guard let a = a else { check(false, "\(msg) (nil)"); return }
    check(abs(a - b) <= tol, "\(msg) (\(a) ≈ \(b) ±\(tol))")
}
// Records a whole section as skipped (fixture absent) so the end-of-run summary shows what
// didn't run, instead of that only being discoverable by scrolling the full log.
func skip(_ section: String, _ reason: String) {
    skippedSections.append(section)
    print("  ⊘ \(reason)")
}

// One-off recorder: SWINGCORE_RECORD_POSE=<out.json> SWINGCORE_RECORD_SRC=<clip.mov>
// → serialize the real Vision pose of the clip and exit (used to capture the replay fixture).
if let outPath = ProcessInfo.processInfo.environment["SWINGCORE_RECORD_POSE"],
   let srcPath = ProcessInfo.processInfo.environment["SWINGCORE_RECORD_SRC"] {
    do {
        let seq = try PoseEstimator.pose(video: URL(fileURLWithPath: srcPath), fps: 30)
        try JSONEncoder().encode(seq).write(to: URL(fileURLWithPath: outPath))
        print("recorded pose: \(seq.frames.count) frames, \(seq.framesDetected) detected → \(outPath)")
        exit(0)
    } catch { FileHandle.standardError.write("record failed: \(error)\n".data(using: .utf8)!); exit(1) }
}

print("== SwingCore checks ==")

// Shared specs for the pipeline/report/session checks (S1 — ClubSpec replaces the old enum).
let pwSpec  = ClubSpec(category: .wedge, loft: 46, label: "PW")
let drSpec  = ClubSpec(category: .driver)
let i7Spec  = ClubSpec(category: .iron, number: 7)

print("[ClubCategory analysisFamily]")
check(ClubCategory.driver.analysisFamily == .driver, "driver family = driver")
check(ClubCategory.wood.analysisFamily == .wood, "wood family = wood")
check(ClubCategory.hybrid.analysisFamily == .wood, "hybrid → wood family")
check(ClubCategory.drivingIron.analysisFamily == .iron, "drivingIron → iron family")
check(ClubCategory.iron.analysisFamily == .iron, "iron family = iron")
check(ClubCategory.wedge.analysisFamily == .wedge, "wedge family = wedge")

print("[ClubSpec]")
check(drSpec.displayName == "Driver", "driver displayName")
check(ClubSpec(category: .wood, number: 3).displayName == "3W", "3W displayName")
check(ClubSpec(category: .hybrid, number: 5).displayName == "5H", "5H displayName")
check(i7Spec.displayName == "7i", "7i displayName")
check(ClubSpec(category: .wedge, loft: 54).displayName == "54°", "54° displayName from loft")
check(pwSpec.displayName == "PW", "explicit label wins in displayName")
do {
    let data = try JSONEncoder().encode(pwSpec)
    let back = try JSONDecoder().decode(ClubSpec.self, from: data)
    check(back == pwSpec, "ClubSpec Codable round-trip (id/category/loft/label)")
} catch { print("  ✗ FAIL: ClubSpec Codable threw \(error)"); failures += 1; total += 1 }
// Legacy tolerance: a pre-ClubSpec Session stored its club as a bare string ("7i","pw").
// Decoding that JSON must map through ClubLegacy so old persisted sessions still open.
do {
    let legacy7i = try JSONDecoder().decode(ClubSpec.self, from: Data("\"7i\"".utf8))
    check(legacy7i.category == .iron && legacy7i.number == 7, "legacy string \"7i\" decodes to iron 7")
    let legacyPw = try JSONDecoder().decode(ClubSpec.self, from: Data("\"pw\"".utf8))
    check(legacyPw.category == .wedge && legacyPw.loft == 46, "legacy string \"pw\" decodes to 46° wedge")
    // A full legacy Session blob (club as a bare string) decodes end-to-end.
    let legacySessionJSON = "{\"id\":\"00000000-0000-0000-0000-000000000000\",\"date\":0,\"club\":\"3w\",\"angle\":\"face_on\",\"hand\":\"R\",\"swings\":[]}"
    let s = try JSONDecoder().decode(Session.self, from: Data(legacySessionJSON.utf8))
    check(s.club.category == .wood && s.club.number == 3, "legacy Session blob with string club decodes (3w → wood 3)")
} catch { print("  ✗ FAIL: legacy club decode threw \(error)"); failures += 1; total += 1 }
// sortKey orders Driver → woods → hybrid → irons → wedges(46→58)
let sortedNames = Bag.sorted(Bag.defaultBag).map { $0.displayName }
check(sortedNames == ["Driver","3W","5H","6i","7i","8i","9i","PW","50°","54°","58°"],
      "defaultBag sortKey order (\(sortedNames))")
let keys = Bag.sorted(Bag.defaultBag).map { $0.sortKey }
check(zip(keys, keys.dropFirst()).allSatisfy { $0 < $1 }, "sortKey strictly increasing in bag order")

print("[Bag]")
check(Bag.defaultBag.count == 11, "default bag has 11 clubs (got \(Bag.defaultBag.count))")
check(Bag.defaultBag.filter { $0.category == .wedge }.compactMap { $0.loft } == [46,50,54,58],
      "default wedges 46/50/54/58")
check(Bag.wedgePrefillLoft(name: "Pitching Wedge") == 46 && Bag.wedgePrefillLoft(name: "pw") == 46, "prefill PW → 46")
check(Bag.wedgePrefillLoft(name: "Gap Wedge") == 50 && Bag.wedgePrefillLoft(name: "gw") == 50, "prefill GW → 50")
check(Bag.wedgePrefillLoft(name: "Sand Wedge") == 56 && Bag.wedgePrefillLoft(name: "sw") == 56, "prefill SW → 56")
check(Bag.wedgePrefillLoft(name: "Lob Wedge") == 60 && Bag.wedgePrefillLoft(name: "lw") == 60, "prefill LW → 60")
check(Bag.suggestedWedgeLabel(loft: 46) == "PW" && Bag.suggestedWedgeLabel(loft: 50) == "GW"
      && Bag.suggestedWedgeLabel(loft: 54) == "SW" && Bag.suggestedWedgeLabel(loft: 58) == "LW",
      "suggestedWedgeLabel 46→PW 50→GW 54→SW 58→LW")

print("[MLM2ProClub.map]")
let mapBag = Bag.defaultBag + [ClubSpec(category: .hybrid, number: 3)]
if case .matched(let c) = MLM2ProClub.map(code: "9i", bag: mapBag) { check(c.category == .iron && c.number == 9, "9i → iron 9") }
else { check(false, "9i should match iron 9") }
if case .matched(let c) = MLM2ProClub.map(code: "3h", bag: mapBag) { check(c.category == .hybrid && c.number == 3, "3h → hybrid 3") }
else { check(false, "3h should match hybrid 3") }
if case .matched(let c) = MLM2ProClub.map(code: "d", bag: mapBag) { check(c.category == .driver, "d → driver") }
else { check(false, "d should match driver") }
if case .matched(let c) = MLM2ProClub.map(code: "pw", bag: mapBag) { check(c.loft == 46, "pw → the 46° wedge") }
else { check(false, "pw should match the single in-range wedge") }
if case .matched(let c) = MLM2ProClub.map(code: "sw", bag: mapBag) { check(c.loft == 54, "sw → 54 (single in-range)") }
else { check(false, "sw should match 54") }
// two wedges in the SW range ⇒ ambiguous
let ambigBag = [ClubSpec(category: .wedge, loft: 54), ClubSpec(category: .wedge, loft: 56)]
if case .ambiguous(let cs) = MLM2ProClub.map(code: "sw", bag: ambigBag) { check(cs.count == 2, "sw ambiguous over {54,56}") }
else { check(false, "sw over {54,56} should be ambiguous") }
check(MLM2ProClub.map(code: "7w", bag: mapBag) == .unknown, "7w not in bag ⇒ unknown")
// override wins
let target = ClubSpec(category: .iron, number: 8)
if case .matched(let c) = MLM2ProClub.map(code: "9i", bag: mapBag + [target], overrides: ["9i": target.id]) {
    check(c.id == target.id, "override forces 9i → the chosen club")
} else { check(false, "override should win") }
check(MLM2ProClub.loft(fromModel: "Cleveland RTX 54") == 54, "loft parsed from model string")

print("[ClubLegacy.map]")
check(ClubLegacy.map(rawValue: "dr").category == .driver, "legacy dr → driver")
let l3w = ClubLegacy.map(rawValue: "3w"); check(l3w.category == .wood && l3w.number == 3, "legacy 3w → wood 3")
let l5w = ClubLegacy.map(rawValue: "5w"); check(l5w.category == .wood && l5w.number == 5, "legacy 5w → wood 5")
for n in 3...9 {
    let li = ClubLegacy.map(rawValue: "\(n)i")
    check(li.category == .iron && li.number == n, "legacy \(n)i → iron \(n)")
}
let lpw = ClubLegacy.map(rawValue: "pw"); check(lpw.category == .wedge && lpw.loft == 46 && lpw.label == "PW", "legacy pw → wedge 46 PW")
let lgw = ClubLegacy.map(rawValue: "gw"); check(lgw.category == .wedge && lgw.loft == 50 && lgw.label == "GW", "legacy gw → wedge 50 GW")
let law = ClubLegacy.map(rawValue: "aw"); check(law.category == .wedge && law.loft == 50 && law.label == "AW", "legacy aw → wedge 50 AW")
let lsw = ClubLegacy.map(rawValue: "sw"); check(lsw.category == .wedge && lsw.loft == 56 && lsw.label == "SW", "legacy sw → wedge 56 SW")
let llw = ClubLegacy.map(rawValue: "lw"); check(llw.category == .wedge && llw.loft == 60 && llw.label == "LW", "legacy lw → wedge 60 LW")

print("[Models]")
var m = SwingMetrics(); m.headSwayIn = 3.9; m.tempoRatio = 3.0
check(m["head_sway_in"] == 3.9, "metrics subscript head_sway_in")
check(m["tempo_ratio"] == 3.0, "metrics subscript tempo_ratio")
check(m["weight_lead_pct_est"] == nil, "metrics subscript nil for unset")

do {
    var mm = SwingMetrics(); mm.headRiseCm = -6.4; mm.leadArmBendDeg = 24.6
    let data = try JSONEncoder().encode(mm)
    let back = try JSONDecoder().decode(SwingMetrics.self, from: data)
    check(back.headRiseCm == -6.4 && back.leadArmBendDeg == 24.6, "SwingMetrics Codable round-trip")
} catch { print("  ✗ FAIL: Codable threw \(error)"); failures += 1; total += 1 }

// [S1] Pose — integration check against a real clip (CLI oracle: 126 frames, all detected).
// Skips gracefully if the clip isn't present (keeps the harness portable).
print("[Pose]")
// No repo-committed fallback: a real swing clip can't be committed (privacy hard rule), so this
// section only runs when a developer points SWINGCORE_TEST_CLIP at one locally. CI/clean clones
// skip it by design — see claude_docs/code-review-findings.md #1.
let clipPath = ProcessInfo.processInfo.environment["SWINGCORE_TEST_CLIP"]
if let clipPath, FileManager.default.fileExists(atPath: clipPath) {
    do {
        let seq = try PoseEstimator.pose(video: URL(fileURLWithPath: clipPath), fps: 30)
        check(seq.frames.count >= 120 && seq.frames.count <= 132, "pose sampled ~126 frames (got \(seq.frames.count))")
        let detectedPct = Double(seq.framesDetected) / Double(max(seq.frames.count, 1))
        check(detectedPct > 0.9, "body detected in >90% of frames (got \(Int(detectedPct*100))%)")
        let mid = seq.frames[seq.frames.count / 2]
        check(mid.joints.count >= 14, "mid-frame has ≥14 joints (got \(mid.joints.count))")

        // [S2] Segment / events / metrics / faults — validated against the CLI golden fixture
        // sessions/2026-07-04_pw/analysis/swing_1.json (face-on, pitching wedge, RH).
        print("[Segment]")
        let windows = Segmenter.swings(in: seq, max: 5)
        check(windows.count >= 1, "segmenter finds ≥1 swing (got \(windows.count))")

        print("[Events]")
        let ev = EventDetector.detect(seq)
        check(ev.address.frame < ev.top.frame && ev.top.frame < ev.impact.frame && ev.impact.frame <= ev.finish.frame,
              "events ordered address<top<impact≤finish (\(ev.address.frame)/\(ev.top.frame)/\(ev.impact.frame)/\(ev.finish.frame))")
        approx(ev.impact.t, 1.87, 0.25, "impact time ≈ CLI 1.87s")
        approx(ev.top.t, 1.40, 0.35, "top time ≈ CLI 1.40s")

        print("[Metrics]")
        let met = MetricsEngine.compute(seq, events: ev, angle: .faceOn)
        approx(met["weight_lead_pct_est"], 28.9, 8, "weight_lead_pct_est ≈ CLI 28.9")
        approx(met["head_sway_in"], 3.9, 1.5, "head_sway_in ≈ CLI 3.9")
        approx(met["head_rise_cm"], -7.3, 3, "head_rise_cm ≈ CLI -7.3")
        approx(met["lead_arm_bend_deg"], 24.6, 4, "lead_arm_bend_deg ≈ CLI 24.6")
        approx(met["xfactor_deg"], 27.4, 5, "xfactor_deg ≈ CLI 27.4")
        approx(met["pelvis_sway_in"], 3.6, 1.5, "pelvis_sway_in ≈ CLI 3.6")
        approx(met["tempo_ratio"], 3.0, 0.8, "tempo_ratio ≈ CLI 3.0")

        print("[Faults]")
        let faults = FaultEvaluator.evaluate(met, category: .wedge, angle: .faceOn)
        let codes = Set(faults.map { $0.code })
        check(codes.contains("chicken_wing"), "detects chicken_wing (CLI did)")
        check(codes.contains("hanging_back"), "detects hanging_back (CLI did)")
        check(codes.contains("low_separation"), "detects low_separation (CLI did)")
        check(faults.allSatisfy { $0.severity >= 0 && $0.severity <= 1 }, "all fault severities in [0,1]")
        let sevs = faults.map { $0.severity }
        check(zip(sevs, sevs.dropFirst()).allSatisfy { $0 >= $1 }, "faults sorted by severity desc")

        // [S3] Reference store + template builder + comparator.
        print("[Reference]")
        check(ReferenceStore.available.count == 8, "8 pro reference slots bundled (got \(ReferenceStore.available.count))")
        let ref = ReferenceStore.template(category: .wedge, angle: .faceOn)
        check(ref != nil, "wedge_face_on template loads from bundle")
        // Regression: new hybrid/drivingIron categories fold onto the existing wood/mid-iron slots.
        check(ReferenceStore.template(category: .hybrid, angle: .faceOn)?.club
              == ReferenceStore.template(category: .wood, angle: .faceOn)?.club, "hybrid loads the wood reference")
        check(ReferenceStore.template(category: .drivingIron, angle: .faceOn)?.club
              == ReferenceStore.template(category: .iron, angle: .faceOn)?.club, "drivingIron loads the mid-iron reference")
        if let ref = ref {
            check(ref.phases.count == 4, "reference has 4 phases (got \(ref.phases.count))")
            let addr = ref.phases[.address] ?? [:]
            check(addr.count >= 12, "reference address phase has ≥12 joints (got \(addr.count))")
            if let lh = addr[.leftHip], let rh = addr[.rightHip] {
                check(abs(lh.x + rh.x) < 0.05 && abs(lh.y + rh.y) < 0.05, "hips normalized symmetric about origin")
            } else { check(false, "reference address has hip joints") }

            print("[Template]")
            let userTpl = TemplateBuilder.build(seq, events: ev, category: .wedge, angle: .faceOn, metrics: met)
            check(userTpl.phases.count == 4, "user template has 4 phases")
            if let lh = userTpl.phases[.address]?[.leftHip], let rh = userTpl.phases[.address]?[.rightHip] {
                check(abs(lh.x + rh.x) < 0.05, "user hips normalized symmetric (\(lh.x) vs \(rh.x))")
            } else { check(false, "user template has hip joints") }

            print("[Comparator]")
            let self0 = PoseComparator.compare(user: userTpl, reference: userTpl, category: .wedge, angle: .faceOn)
            check(self0.overall == 1.0, "self-comparison overall == 1.0 (got \(self0.overall))")
            check(self0.perPhaseMatch.values.allSatisfy { $0 == 1.0 }, "self-comparison all phases == 1.0")
            let cmp = PoseComparator.compare(user: userTpl, reference: ref, category: .wedge, angle: .faceOn)
            check(cmp.overall > 0 && cmp.overall <= 1, "user-vs-pro overall in (0,1] (got \(cmp.overall))")
            check(cmp.perPhaseMatch.values.allSatisfy { $0 > 0 && $0 <= 1 }, "user-vs-pro phase matches in (0,1]")
            check(cmp.deltas["weight_lead_pct_est"] != nil, "deltas include weight_lead_pct_est")
        }

        // [S3.5] End-to-end facade: analyze(video:) and analyzeSession(video:).
        print("[Pipeline]")
        let one = try SwingAnalyzer.analyze(seq, club: pwSpec, angle: .faceOn)
        check(one.faults.count >= 1 && one.comparison != nil, "analyze() yields faults + comparison")
        check(one.events.impact.frame == ev.impact.frame, "facade events match direct EventDetector")
        let sessionSwings = try SwingAnalyzer.analyze(seq, club: pwSpec, angle: .faceOn, index: 1)
        let st = SessionBuilder.stats([sessionSwings])
        check(st.bestSwing == 1, "single-swing session best == 1")
        check(st.focus != "keep grooving contact", "focus names the dominant fault (\(st.focus))")
        check(st.recurringFaults["chicken_wing"] == 1, "recurring faults count chicken_wing once")

        // [S3.6] Public benchmark accessor for the UI.
        print("[Benchmarks]")
        let bDriver = FaultEvaluator.benchmarks(category: .driver)
        let bWedge = FaultEvaluator.benchmarks(category: .wedge)
        let bIron = FaultEvaluator.benchmarks(category: .iron)
        check(bWedge.count == 9, "9 benchmark rows")
        // Regression: iron benchmarks identical to the old mid-iron defaults (no override).
        if let w0 = bIron.first(where: { $0.key == "weight_lead_pct_est" }) {
            check(w0.good == 80 && w0.fault == 70, "iron weight target 80/70 (defaults, unchanged)")
        } else { check(false, "iron weight benchmark present") }
        // Regression: hybrid folds onto wood benchmarks; drivingIron onto iron.
        let bHybrid = FaultEvaluator.benchmarks(category: .hybrid)
        if let h = bHybrid.first(where: { $0.key == "weight_lead_pct_est" }) {
            check(h.good == 65 && h.fault == 55, "hybrid weight target 65/55 (= wood override)")
        } else { check(false, "hybrid weight benchmark present") }
        if let w = bWedge.first(where: { $0.key == "weight_lead_pct_est" }),
           let d0 = bDriver.first(where: { $0.key == "weight_lead_pct_est" }) {
            check(w.good == 85 && w.fault == 75, "wedge weight target 85/75")
            check(d0.good == 60 && d0.fault == 50, "driver weight target 60/50 (club override)")
            check(w.higherIsBetter, "weight_lead higherIsBetter (min-direction)")
        } else { check(false, "weight benchmark present for both clubs") }

        // [P1.2] SwingLines — coach geometry from pose (impact frame).
        print("[SwingLines]")
        let lines = SwingLines.lines(seq, at: ev.impact.frame)
        check(lines["shoulder"] != nil && lines["hip"] != nil && lines["spine"] != nil && lines["leadArm"] != nil,
              "shoulder/hip/spine/leadArm lines present")
        if let sh = lines["shoulder"] {
            let dx = abs(sh.a.x - sh.b.x), dy = abs(sh.a.y - sh.b.y)
            check(dx > dy, "face-on shoulder line more horizontal than vertical (dx \(String(format:"%.3f",dx)) > dy \(String(format:"%.3f",dy)))")
            let inRange = [sh.a.x, sh.a.y, sh.b.x, sh.b.y].allSatisfy { $0 >= 0 && $0 <= 1 }
            check(inRange, "shoulder endpoints in [0,1]")
            approx(Double(sh.a.x), 0.560, 0.02, "shoulder a.x golden")
            approx(Double(sh.b.x), 0.370, 0.02, "shoulder b.x golden")
        }
        let hp = SwingLines.handPath(seq, from: ev.address.frame, to: ev.finish.frame)
        let span = ev.finish.frame - ev.address.frame
        check(hp.count >= span/2, "hand-path has ≥ half the swing frames (\(hp.count) of \(span))")
        check(hp.allSatisfy { $0.x.isFinite && $0.y.isFinite }, "hand-path points finite")
        let hb = SwingLines.headBox(seq, events: ev)
        check(hb.width.isFinite && hb.height.isFinite && hb.width >= 0 && hb.height >= 0, "head box finite, non-negative")
        approx(Double(hb.width), 0.123, 0.03, "head box width golden")

        // [P1.6] AngleDetector — face-on fixture ground truth.
        print("[AngleDetector]")
        let det = AngleDetector.detect(seq, events: ev)
        check(det.angle == .faceOn, "classifies fixture as face-on (got \(det.angle.rawValue))")
        check(det.confidence > 0.6, "confidence > 0.6 (got \(String(format:"%.2f",det.confidence)))")
        approx(det.confidence, 0.675, 0.06, "angle confidence golden")
        let empty = PoseSequence(fps: 30, width: 1080, height: 1920, frames: [])
        let z = SwingEvent(t: 0, frame: 0)
        let ed = AngleDetector.detect(empty, events: SwingEvents(address: z, top: z, impact: z, finish: z))
        check(ed.angle == .faceOn && ed.confidence == 0, "empty pose → default face-on, confidence 0")

        // [P1.6] AngleDetector — down-the-line fixture ground truth (the other class).
        // No repo fallback (real clip, un-committable) — set SWINGCORE_TEST_DTL_CLIP locally to run this.
        let dtlPath = ProcessInfo.processInfo.environment["SWINGCORE_TEST_DTL_CLIP"]
        if let dtlPath, FileManager.default.fileExists(atPath: dtlPath) {
            do {
                let dseq = try PoseEstimator.pose(video: URL(fileURLWithPath: dtlPath), fps: 30)
                let ddet = AngleDetector.detect(dseq, events: EventDetector.detect(dseq))
                check(ddet.angle == .dtl,
                      "classifies DTL fixture as down-the-line (got \(ddet.angle.rawValue), conf \(String(format:"%.2f", ddet.confidence)))")
            } catch { print("  ✗ FAIL: DTL pose threw \(error)"); failures += 1; total += 1 }
        } else {
            skip("AngleDetector.dtl", "DTL fixture absent (set SWINGCORE_TEST_DTL_CLIP to enable)")
        }

        // [P2.4] SequenceEngine + [P2.3] headTravelCm + [P2.1] auto-trim (clip-dependent).
        print("[P2 clip]")
        let kseq = SequenceEngine.compute(seq, events: ev)
        check(kseq.peakTimes.count == 4, "kinematic sequence has 4 segment peaks")
        check(Set(kseq.order) == Set(SequenceEngine.segments), "order is a permutation of the 4 segments")
        let topT = ev.top.t, impBuf = ev.impact.t + 0.2
        check(kseq.peakTimes.values.allSatisfy { $0 >= topT - 0.06 && $0 <= impBuf + 0.06 }, "peaks between top and just-after-impact")
        let htc = SwingLines.headTravelCm(seq, events: ev, angle: .faceOn)
        check(htc.isFinite && htc >= 0, "head travel finite ≥ 0")
        approx(htc, 74.5, 20.0, "head travel golden (cm)")
        if let win = Segmenter.swings(in: seq, max: 1).first {
            check(ev.impact.t >= win.start && ev.impact.t <= win.end, "auto-trim window contains impact")
        } else { check(false, "segmenter returns a window") }
    } catch { print("  ✗ FAIL: pose threw \(error)"); failures += 1; total += 1 }
} else {
    skip("Pose+Segment+Events+Metrics+Faults+Reference+Template+Comparator+Pipeline+Benchmarks+SwingLines+AngleDetector+P2clip",
         "no test clip (set SWINGCORE_TEST_CLIP to enable)")
}

// [Pipeline degenerate] — SwingAnalyzer.analyze(_ pose:) guards, no clip needed (findings #2, #6).
print("[Pipeline degenerate]")
let empty0 = PoseSequence(fps: 30, width: 1080, height: 1920, frames: [])
do { _ = try SwingAnalyzer.analyze(empty0, club: pwSpec, angle: .faceOn); check(false, "0-frame pose should throw") }
catch SwingError.noSwingDetected { check(true, "0-frame pose throws noSwingDetected") }
catch { check(false, "0-frame pose threw wrong error: \(error)") }

let oneFrame = PoseSequence(fps: 30, width: 1080, height: 1920, frames: [PoseFrame(t: 0, joints: [:])])
do { _ = try SwingAnalyzer.analyze(oneFrame, club: pwSpec, angle: .faceOn); check(false, "1-frame pose should throw") }
catch SwingError.noSwingDetected { check(true, "1-frame pose throws noSwingDetected") }
catch { check(false, "1-frame pose threw wrong error: \(error)") }

// finding #6 — lead wrist never detected across an otherwise-plausible clip (occluded/out of
// frame/bad angle): every other joint is present in every frame, only the lead wrist is missing.
func noWristPose() -> PoseSequence {
    var frames: [PoseFrame] = []
    for i in 0..<20 {
        frames.append(PoseFrame(t: Double(i)/30, joints: [
            .leftShoulder: JointPoint(x: 0.42, y: 0.75, c: 1), .rightShoulder: JointPoint(x: 0.58, y: 0.75, c: 1),
            .leftHip: JointPoint(x: 0.45, y: 0.55, c: 1), .rightHip: JointPoint(x: 0.55, y: 0.55, c: 1),
        ]))  // leftWrist deliberately absent in every frame
    }
    return PoseSequence(fps: 30, width: 1000, height: 1000, frames: frames)
}
do { _ = try SwingAnalyzer.analyze(noWristPose(), club: pwSpec, angle: .faceOn); check(false, "fully-undetected lead wrist should throw") }
catch SwingError.lowPoseConfidence { check(true, "fully-undetected lead wrist throws lowPoseConfidence") }
catch { check(false, "wrong error for undetected wrist: \(error)") }

// [P1.5] Trends — pure aggregation over synthetic sessions (no clip needed).
print("[Trends]")
// Two sessions share ONE wedge identity (same ClubSpec.id) so per-club trends group correctly.
let trendPW = ClubSpec(category: .wedge, loft: 46, label: "PW")
let trend7i = ClubSpec(category: .iron, number: 7)
func mkSession(_ day: Int, _ club: ClubSpec, _ headSway: Double) -> Session {
    var mm = SwingMetrics(); mm.headSwayIn = headSway
    let evs = SwingEvents(address: SwingEvent(t: 0, frame: 0), top: SwingEvent(t: 1, frame: 30),
                          impact: SwingEvent(t: 1.8, frame: 54), finish: SwingEvent(t: 4, frame: 120))
    let sa = SwingAnalysis(index: 1, events: evs, metrics: mm, faults: [])
    return Session(date: Date(timeIntervalSince1970: Double(day) * 86400), club: club, angle: .faceOn,
                   hand: .right, swings: [sa], stats: SessionStats(bestSwing: 1, recurringFaults: [:], focus: "x"))
}
let sess = [mkSession(3, trendPW, 3.0), mkSession(1, trendPW, 5.0), mkSession(2, trend7i, 4.0)]
let ser = Trends.series(sess, metric: "head_sway_in", clubID: trendPW.id)
check(ser.count == 2, "trends filters to the PW club identity (got \(ser.count))")
check(ser.map { $0.date } == ser.map { $0.date }.sorted(by: <), "trends date-ordered")
check(ser.first?.value == 5.0 && ser.last?.value == 3.0, "trends values in date order (5.0 → 3.0)")
let rm = Trends.rollingMean(ser, window: 2)
check(abs((rm.last?.value ?? 0) - 4.0) < 1e-9, "rolling mean of [5,3] w2 last == 4.0")
check(Trends.series(sess, metric: "head_sway_in", clubID: nil).count == 3, "no id filter → all 3 sessions")
check(Trends.series(sess, metric: "head_sway_in", category: .wedge).count == 2, "category filter → 2 wedge sessions")

// [P1.8] ReportBuilder — deterministic Markdown summary.
print("[Report]")
var rmet = SwingMetrics(); rmet.tempoRatio = 3.0; rmet.leadArmBendDeg = 24.6; rmet.weightLeadPctEst = 28.9
let rfaults = FaultEvaluator.evaluate(rmet, category: .wedge, angle: .faceOn)
let revs = SwingEvents(address: SwingEvent(t: 0, frame: 0), top: SwingEvent(t: 1.4, frame: 42),
                       impact: SwingEvent(t: 1.87, frame: 56), finish: SwingEvent(t: 4.13, frame: 124))
let rsa = SwingAnalysis(index: 1, events: revs, metrics: rmet, faults: rfaults)
let rsession = Session(date: Date(timeIntervalSince1970: 0), club: pwSpec, angle: .faceOn, hand: .right,
                       swings: [rsa], stats: SessionBuilder.stats([rsa]))
let md = ReportBuilder.markdown(rsession)
check(md.contains("PW"), "report contains club displayName")
check(!rfaults.isEmpty && md.contains(rfaults[0].code), "report contains top fault code (\(rfaults.first?.code ?? "none"))")
check(md.contains("3.0 : 1"), "report contains tempo value")

// [P2.1] FramingGuide — pure, no clip needed.
print("[FramingGuide]")
func fullBody() -> [Joint: JointPoint] {
    func p(_ x: Double, _ y: Double) -> JointPoint { JointPoint(x: x, y: y, c: 1) }
    return [
        .nose: p(0.5, 0.90), .leftShoulder: p(0.42, 0.75), .rightShoulder: p(0.58, 0.75),
        .leftHip: p(0.45, 0.55), .rightHip: p(0.55, 0.55),
        .leftKnee: p(0.45, 0.35), .rightKnee: p(0.55, 0.35),
        .leftAnkle: p(0.45, 0.15), .rightAnkle: p(0.55, 0.15),
    ]
}
check(FramingGuide.inFrame(fullBody()).ok, "full body in frame ⇒ ok")
var noAnkle = fullBody(); noAnkle[.leftAnkle] = nil
check(!FramingGuide.inFrame(noAnkle).ok, "missing ankle ⇒ not ok")
var edge = fullBody(); edge[.rightShoulder] = JointPoint(x: 0.995, y: 0.75, c: 1)
check(!FramingGuide.inFrame(edge).ok, "joint at edge ⇒ not ok")

// [C6] dtlInFrame — side-on detection.
func sideOn() -> [Joint: JointPoint] {
    var j = fullBody()
    j[.leftShoulder] = JointPoint(x: 0.50, y: 0.75, c: 1)   // shoulders nearly aligned (side-on)
    j[.rightShoulder] = JointPoint(x: 0.46, y: 0.75, c: 1)
    return j
}
check(FramingGuide.dtlInFrame(sideOn()).ok, "side-on pose ⇒ DTL ok")
check(!FramingGuide.dtlInFrame(fullBody()).ok, "wide-shoulder face-on ⇒ not DTL")
var dtlNoAnkle = sideOn(); dtlNoAnkle[.leftAnkle] = nil
check(!FramingGuide.dtlInFrame(dtlNoAnkle).ok, "DTL missing ankle ⇒ not ok")

// [P2.1] MotionTrigger — pure.
print("[MotionTrigger]")
var burst = [Double](repeating: 0.2, count: 40)
for i in 18...24 { burst[i] = Double(6 - abs(21 - i)) }  // clear peak at 21
if let w = MotionTrigger.swingWindow(leadWristSpeed: burst, fps: 30) {
    check(w.startIdx <= 21 && w.endIdx >= 21, "motion window brackets the peak (\(w.startIdx)…\(w.endIdx))")
} else { check(false, "burst series ⇒ a window") }
check(MotionTrigger.swingWindow(leadWristSpeed: [Double](repeating: 1.0, count: 40), fps: 30) == nil, "flat series ⇒ nil")

// [P2.2] EventAlignment — pure.
print("[EventAlignment]")
let ea = SwingEvents(address: SwingEvent(t: 0, frame: 0), top: SwingEvent(t: 1.0, frame: 30),
                     impact: SwingEvent(t: 1.5, frame: 45), finish: SwingEvent(t: 3.0, frame: 90))
let eb = SwingEvents(address: SwingEvent(t: 2.0, frame: 0), top: SwingEvent(t: 3.0, frame: 30),
                     impact: SwingEvent(t: 3.4, frame: 45), finish: SwingEvent(t: 5.0, frame: 90))
check(abs(EventAlignment.mapTime(1.5, from: ea, to: eb) - 3.4) < 1e-9, "A.impact maps exactly to B.impact")
check(abs(EventAlignment.mapTime(0.5, from: ea, to: eb) - 2.5) < 1e-9, "midpoint address→top interpolates")
check(EventAlignment.mapTime(-1, from: ea, to: eb) == 2.0 && EventAlignment.mapTime(9, from: ea, to: eb) == 5.0, "clamps to B endpoints")

// [P2.5] HapticBeats — pure.
print("[HapticBeats]")
let hb2 = HapticBeats.offsets(ea)
check(hb2.count == 2 && hb2[0] < hb2[1], "two ordered beat offsets")
let beatRatio = hb2[0] / (hb2[1] - hb2[0])
let tempo = (ea.top.t - ea.address.t) / (ea.impact.t - ea.top.t)
check(abs(beatRatio - tempo) < 1e-9, "beat ratio ≈ tempo ratio (\(String(format:"%.2f",beatRatio)))")

// [P2.4] SequenceEngine — synthetic invariant (no clip).
print("[SequenceEngine invariant]")
func seqPose(pelvis: Int, torso: Int, arm: Int, hand: Int) -> PoseSequence {
    func off(_ i: Int, _ f: Int) -> Double { i >= f ? 0.10 : 0 }
    var frames: [PoseFrame] = []
    for i in 0..<10 {
        func p(_ x: Double, _ y: Double) -> JointPoint { JointPoint(x: x, y: y, c: 1) }
        let j: [Joint: JointPoint] = [
            .leftHip: p(0.45, 0.50), .rightHip: p(0.55, 0.50 + off(i, pelvis)),
            .leftShoulder: p(0.42, 0.68), .rightShoulder: p(0.58, 0.68 + off(i, torso)),
            .leftElbow: p(0.40 - off(i, arm), 0.58),
            // non-degenerate hand vector (dx≠0): arm shifts both x equally, hand rotates wrist.x
            .leftWrist: p(0.44 - off(i, arm) + off(i, hand), 0.50),
        ]
        frames.append(PoseFrame(t: Double(i) / 30.0, joints: j))
    }
    return PoseSequence(fps: 30, width: 1000, height: 1000, frames: frames)
}
let seqEvents = SwingEvents(address: SwingEvent(t: 0, frame: 0), top: SwingEvent(t: 1/30, frame: 1),
                            impact: SwingEvent(t: 8/30, frame: 8), finish: SwingEvent(t: 9/30, frame: 9))
let inOrder = SequenceEngine.compute(seqPose(pelvis: 2, torso: 4, arm: 6, hand: 8), events: seqEvents)
check(inOrder.inSequence, "pelvis→torso→arm→hand ⇒ inSequence true")
let reversed = SequenceEngine.compute(seqPose(pelvis: 8, torso: 6, arm: 4, hand: 2), events: seqEvents)
check(!reversed.inSequence, "reversed order ⇒ inSequence false")

// [P3.1] MLM2PRO CSV parser — golden check against a committed fixture.
// validate.sh exports SWINGCORE_TEST_CSV at the repo's own ios/DivotTests/Fixtures/sample_shots.csv
// by default, so this runs in CI/on a clean clone with no manual setup.
print("[MLM2ProCSV]")
let csvPath = ProcessInfo.processInfo.environment["SWINGCORE_TEST_CSV"]
if let csvPath, let csvText = try? String(contentsOfFile: csvPath, encoding: .utf8) {
    let rows = MLM2ProCSV.parse(csvText)
    check(rows.count == 5, "parses 5 shot rows (got \(rows.count))")
    if rows.count >= 2 {
        check(rows[0].clubType == "9i", "row 1 club == 9i (\(rows[0].clubType))")
        approx(rows[0].ballSpeed, 24.7, 0.001, "row 1 ball speed 24.7")
        approx(rows[0].carryDistance, 8.0, 0.001, "row 1 carry 8.0")
        approx(rows[1].clubSpeed, 39.5, 0.001, "row 2 club speed 39.5")
        approx(rows[0].spinRate, 10254, 0.5, "row 1 spin rate 10254")
        check(rows[0].clubBrand == nil, "blank cell → nil (club brand)")
    }
    // malformed / short line is skipped, not crashed
    let robust = MLM2ProCSV.parse(csvText + "\n\"bad\",row\n,,,\n")
    check(robust.count >= 5, "malformed/short lines skipped, not crashed (got \(robust.count))")
    // header-only input → no rows
    check(MLM2ProCSV.parse(csvText.split(separator: "\n").first.map(String.init) ?? "").isEmpty, "header-only ⇒ no rows")
} else {
    skip("MLM2ProCSV", "no CSV fixture (set SWINGCORE_TEST_CSV to enable; validate.sh sets a repo default)")
}

// [Mock] ReplayPoseProvider — the whole pipeline runs from a recorded pose (Simulator/CI path).
// validate.sh exports SWINGCORE_TEST_POSE_JSON at the repo's own sample_swing.pose.json by default.
print("[Replay]")
let poseJSON = ProcessInfo.processInfo.environment["SWINGCORE_TEST_POSE_JSON"]
if let poseJSON, FileManager.default.fileExists(atPath: poseJSON) {
    do {
        let replay = try ReplayPoseProvider(contentsOf: URL(fileURLWithPath: poseJSON))
        check(replay.sequence.frames.count > 100, "replay pose has frames (\(replay.sequence.frames.count))")
        // Full facade via the mock provider (URL is ignored by ReplayPoseProvider).
        let session = try SwingAnalyzer.analyzeSession(video: URL(fileURLWithPath: "/dev/null"),
                                                       club: pwSpec, angle: .faceOn, provider: replay)
        check(!session.swings.isEmpty, "replay session has a swing")
        let sw = session.swings[0]
        check(sw.events.address.frame < sw.events.top.frame && sw.events.top.frame < sw.events.impact.frame,
              "replay events ordered")
        approx(sw.events.impact.t, 1.87, 0.3, "replay impact ≈ 1.87s")
        let rcodes = Set(sw.faults.map { $0.code })
        check(rcodes.contains("chicken_wing") || rcodes.contains("hanging_back"), "replay yields known faults \(rcodes)")
        check(sw.comparison != nil && (sw.comparison?.overall ?? 0) > 0, "replay yields pro comparison")
        // Faithfulness: on macOS Vision runs, so live pose of the same fixture must match the recording.
        // Reuses SWINGCORE_TEST_CLIP (the [Pose] section's clip) rather than a second hardcoded
        // path — sample_swing.pose.json was recorded from that same real clip.
        if let clipPath, FileManager.default.fileExists(atPath: clipPath) {
            let live = try PoseEstimator.pose(video: URL(fileURLWithPath: clipPath), fps: 30)
            check(EventDetector.detect(live).impact.frame == EventDetector.detect(replay.sequence).impact.frame,
                  "replay matches live Vision impact frame (faithful capture)")
        }
    } catch { print("  ✗ FAIL: replay threw \(error)"); failures += 1; total += 1 }
} else {
    skip("Replay", "replay pose JSON absent (set SWINGCORE_TEST_POSE_JSON; validate.sh sets a repo default)")
}

// [ClubPath] C1-C5 — target/plane geometry, ball detect, over-the-top, ball-flight link, club tracker.
print("[ClubPath]")
func cpFrame(_ t: Double, _ wristX: Double, _ wristY: Double) -> PoseFrame {
    PoseFrame(t: t, joints: [
        .leftWrist: JointPoint(x: wristX, y: wristY, c: 1),
        .leftShoulder: JointPoint(x: 0.6, y: 0.7, c: 1), .rightShoulder: JointPoint(x: 0.4, y: 0.7, c: 1),
        .leftHip: JointPoint(x: 0.55, y: 0.5, c: 1), .rightHip: JointPoint(x: 0.45, y: 0.5, c: 1),
    ])
}
func cpPose(_ overX: Double) -> PoseSequence {
    var frames = [cpFrame(0, 0.5, 0.6)]                                  // address → grip top-left (0.5,0.4)
    for i in 1...5 { frames.append(cpFrame(Double(i) / 30, overX, 0.5)) }
    return PoseSequence(fps: 30, width: 1000, height: 1000, frames: frames)
}
let cpEvents = SwingEvents(address: SwingEvent(t: 0, frame: 0), top: SwingEvent(t: 1/30, frame: 1),
                           impact: SwingEvent(t: 5/30, frame: 5), finish: SwingEvent(t: 5/30, frame: 5))
let cpBall = CGPoint(x: 0.5, y: 0.9)

let tl = SwingLines.targetLine(ball: CGPoint(x: 0.5, y: 0.85))
check(tl.a.y == tl.b.y && tl.a.y == 0.85, "C1 target line horizontal at ball height")
let sp = SwingLines.shaftPlane(cpPose(0.2), events: cpEvents, hand: .right, ball: cpBall)
let cross = (Double(sp.b.x) - Double(sp.a.x)) * (Double(cpBall.y) - Double(sp.a.y))
          - (Double(sp.b.y) - Double(sp.a.y)) * (Double(cpBall.x) - Double(sp.a.x))
check(abs(cross) < 1e-6 && sp.a.x.isFinite && sp.b.y.isFinite, "C1 shaft plane passes through ball + finite")

func circleImage(_ cx: Double, _ cy: Double, _ r: Double, _ size: Int = 100) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    if r > 0 { ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: cx * Double(size) - r, y: cy * Double(size) - r, width: 2 * r, height: 2 * r)) }
    return ctx.makeImage()
}
if let img = circleImage(0.5, 0.5, 8) {
    let d = BallDetector.detectAtAddress(image: img)
    check(d != nil, "C2 ball detected in synthetic image")
    if let d = d { check(abs(Double(d.point.x) - 0.5) < 0.1 && abs(Double(d.point.y) - 0.5) < 0.1, "C2 ball near center") }
}
if let imgL = circleImage(0.25, 0.5, 8), let d = BallDetector.detectAtAddress(image: imgL) {
    check(Double(d.point.x) < 0.4, "C2 left-half ball ⇒ x<0.4 (\(d.point.x))")
}
if let blank = circleImage(0.5, 0.5, 0) { check(BallDetector.detectAtAddress(image: blank) == nil, "C2 blank image ⇒ nil") }

let over = PlaneEngine.analyze(cpPose(0.2), events: cpEvents, hand: .right, ball: cpBall)
check(over.overTheTop, "C3 over-the-top synthetic ⇒ true (maxAbove \(over.maxAbovePlane))")
let shallow = PlaneEngine.analyze(cpPose(0.6), events: cpEvents, hand: .right, ball: cpBall)
check(!shallow.overTheTop, "C3 shallow synthetic ⇒ false (maxAbove \(shallow.maxAbovePlane))")
if let poseJSON, FileManager.default.fileExists(atPath: poseJSON), let rp = try? ReplayPoseProvider(contentsOf: URL(fileURLWithPath: poseJSON)) {
    let pa = PlaneEngine.analyze(rp.sequence, events: EventDetector.detect(rp.sequence), angle: .faceOn, hand: .right, ball: nil)
    check(pa.maxAbovePlane.isFinite && pa.source == "hand", "C3 replay plane finite, source hand")
}

var bobs: [(CGPoint, Double)] = []
for i in 0..<10 { let x = Double(i) / 10; bobs.append((CGPoint(x: x, y: 0.9 - x * x), 1)) }
let linked = BallFlightTracer.link(bobs)
check(linked.count == 10, "C4 ball-flight link keeps finite points (\(linked.count))")
check(zip(linked, linked.dropFirst()).allSatisfy { Double($0.0.x) <= Double($0.1.x) + 1e-9 }, "C4 ball-flight x non-decreasing")
check(BallFlightTracer.link([]).isEmpty, "C4 empty ⇒ empty")

var dets: [(t: Double, pt: CGPoint?, conf: Double)] = []
for i in 0..<10 { let ok = i % 3 != 0; dets.append((Double(i) / 30, ok ? CGPoint(x: Double(i) / 10, y: 0.5) : nil, ok ? 0.9 : 0)) }
let cpath = ClubTracker.path(detections: dets)
check(cpath.points.count == 10, "C5 club tracker fills gaps to full length (\(cpath.points.count))")
check(zip(cpath.points, cpath.points.dropFirst()).allSatisfy { $0.0.t <= $0.1.t }, "C5 club path monotonic in time")
check(cpath.points.allSatisfy { $0.pos.x.isFinite && $0.pos.y.isFinite }, "C5 club path finite")
check(cpath.coverage > 0 && cpath.coverage <= 1, "C5 coverage in (0,1] (\(cpath.coverage))")
check(ClubTracker.path(detections: []).points.isEmpty, "C5 empty detections ⇒ empty")

do {
    let plane = PlaneAnalysis(plane: SwingLine(a: CGPoint(x: 0, y: 0.2), b: CGPoint(x: 1, y: 0.8)),
                              overTheTop: true, maxAbovePlane: 0.42, source: "hand", downswingPath: [CGPoint(x: 0.2, y: 0.5)])
    let chp = ClubHeadPath(points: [ClubPoint(t: 0.1, pos: CGPoint(x: 0.3, y: 0.4), conf: 0.8)], coverage: 0.7)
    let bf = BallFlight(points: [CGPoint(x: 0.5, y: 0.5)], detected: true)
    let sa = SwingAnalysis(index: 1, events: cpEvents, metrics: SwingMetrics(), faults: [], comparison: nil,
                           plane: plane, ball: cpBall, clubHeadPath: chp, ballFlight: bf)
    let back = try JSONDecoder().decode(SwingAnalysis.self, from: JSONEncoder().encode(sa))
    check(back.plane?.overTheTop == true && abs((back.plane?.maxAbovePlane ?? 0) - 0.42) < 1e-9, "C-model plane round-trip")
    check(Double(back.ball?.x ?? 0) == 0.5 && back.clubHeadPath?.coverage == 0.7 && back.ballFlight?.detected == true,
          "C-model ball/club/flight round-trip")
} catch { check(false, "C-model SwingAnalysis round-trip threw \(error)") }

if !skippedSections.isEmpty {
    print("-- skipped sections (fixture-gated, absent this run): \(skippedSections.joined(separator: ", ")) --")
}
print(failures == 0 ? "ALL PASS, \(total) checks" : "\(failures) FAILURE(S) of \(total) checks")
exit(failures == 0 ? 0 : 1)
