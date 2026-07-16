import Foundation

// Stages ⑤⑥⑦ — events + biomechanical metrics + fault evaluation.
// Ported faithfully from the validated CLI `analyze.swift` (operating on a PoseSequence).

// MARK: - Smoothed joint series

struct JointSeries {
    let n: Int
    let w: Double, h: Double
    let fps: Double
    let times: [Double]
    private var xs: [Joint: [Double]] = [:]
    private var ys: [Joint: [Double]] = [:]

    init(_ pose: PoseSequence) {
        n = pose.frames.count
        w = Double(pose.width); h = Double(pose.height)
        fps = pose.fps
        times = pose.frames.map { $0.t }
        for j in Joint.allCases {
            var x = [Double](repeating: .nan, count: n), y = x
            // Per-frame Vision confidence, threaded into smoothing below (finding #9b) so a
            // barely-passing detection (just above PoseEstimator's flat minConfidence cutoff)
            // doesn't get weighted identically to a confident one. Gap-filled/interpolated frames
            // (the joint wasn't detected at all that frame) default to full weight (1.0) — interp
            // already handles those gaps, so they shouldn't be double-penalized here too.
            var c = [Double](repeating: 1.0, count: n)
            for (i, f) in pose.frames.enumerated() {
                if let p = f.joints[j] { x[i] = p.x; y[i] = p.y; c[i] = p.c }
            }
            JointSeries.interp(&x); JointSeries.interp(&y)
            xs[j] = JointSeries.smooth(x, weights: c); ys[j] = JointSeries.smooth(y, weights: c)
        }
    }
    func jx(_ j: Joint) -> [Double] { xs[j] ?? [Double](repeating: .nan, count: n) }
    func jy(_ j: Joint) -> [Double] { ys[j] ?? [Double](repeating: .nan, count: n) }

    static func interp(_ a: inout [Double]) {
        var last = -1
        for i in 0..<a.count where !a[i].isNaN {
            if last >= 0 && i - last > 1 { for k in (last+1)..<i { let f = Double(k-last)/Double(i-last); a[k] = a[last]*(1-f)+a[i]*f } }
            last = i
        }
        if let f = a.firstIndex(where: { !$0.isNaN }) { for k in 0..<f { a[k] = a[f] } }
        if let l = a.lastIndex(where: { !$0.isNaN }) { for k in (l+1)..<a.count { a[k] = a[l] } }
    }
    /// `weights`, if provided, down-weights low-confidence samples in the moving average instead
    /// of treating every in-window sample as equally trustworthy (finding #9b). Declared with
    /// `win` still the second positional parameter and `weights` trailing/labeled, so every
    /// existing unlabeled call site (`smooth(a)`, `smooth(a, win)`) keeps compiling unchanged.
    static func smooth(_ a: [Double], _ win: Int = 3, weights: [Double]? = nil) -> [Double] {
        var o = a
        for i in 0..<a.count { var s = 0.0, c = 0.0
            for k in max(0,i-win)...min(a.count-1,i+win) where !a[k].isNaN {
                let wt = weights?[k] ?? 1
                s += a[k] * wt; c += wt
            }
            o[i] = c > 0 ? s/c : a[i] }
        return o
    }
}

private func argmax(_ a: [Double], _ lo: Int, _ hi: Int) -> Int { var bi = lo, bv = -Double.infinity; for i in lo..<hi where a[i] > bv { bv = a[i]; bi = i }; return bi }
private func argmin(_ a: [Double], _ lo: Int, _ hi: Int) -> Int { var bi = lo, bv = Double.infinity; for i in lo..<hi where a[i] < bv { bv = a[i]; bi = i }; return bi }

// MARK: - Events

public enum EventDetector {
    public static func detect(_ pose: PoseSequence, hand: Hand = .right) -> SwingEvents {
        detect(JointSeries(pose), hand: hand)
    }
    /// JointSeries-accepting overload: lets a caller that already built a series for this pose
    /// (e.g. SwingAnalyzer.analyze, which also feeds MetricsEngine/PlaneEngine from the same one)
    /// skip rebuilding it — JointSeries.init does a per-joint interpolation + smoothing pass over
    /// every frame, and was previously rebuilt 5-12x per swing/screen load for identical input.
    static func detect(_ s: JointSeries, hand: Hand = .right) -> SwingEvents {
        let n = s.n
        let lead: Joint = hand.leadWrist
        let lwx = s.jx(lead), lwy = s.jy(lead)
        var speed = [Double](repeating: 0, count: n)
        for i in 1..<max(1, n) { let dx = (lwx[i]-lwx[i-1])*s.w, dy = (lwy[i]-lwy[i-1])*s.h; speed[i] = (dx*dx+dy*dy).squareRoot() }
        speed = JointSeries.smooth(speed, 2)
        let iLo = max(1, Int(0.15*Double(n))), iHi = max(2, min(n, Int(0.92*Double(n))))
        let impact = argmax(speed, iLo, iHi)
        let top = argmax(lwy, 0, max(1, impact))
        let address = argmin(lwy, 0, max(1, top))
        let finish = n - 1
        func ev(_ i: Int) -> SwingEvent { SwingEvent(t: s.times[i], frame: i) }
        return SwingEvents(address: ev(address), top: ev(top), impact: ev(impact), finish: ev(finish))
    }
}

// MARK: - Metrics

public enum MetricsEngine {
    public static func compute(_ pose: PoseSequence, events: SwingEvents, angle: Angle, hand: Hand = .right) -> SwingMetrics {
        compute(JointSeries(pose), events: events, angle: angle, hand: hand)
    }
    /// JointSeries-accepting overload — see EventDetector.detect's overload for why.
    static func compute(_ s: JointSeries, events: SwingEvents, angle: Angle, hand: Hand = .right) -> SwingMetrics {
        let lead = hand == .left ? "right" : "left", trail = hand == .left ? "left" : "right"
        func J(_ side: String, _ part: String) -> Joint { Joint.bySideAndPart(side, part) }
        let a = events.address.frame, top = events.top.frame, imp = events.impact.frame
        var m = SwingMetrics()

        func midX(_ j1: Joint, _ j2: Joint, _ i: Int) -> Double { (s.jx(j1)[i] + s.jx(j2)[i]) / 2 }
        func midY(_ j1: Joint, _ j2: Joint, _ i: Int) -> Double { (s.jy(j1)[i] + s.jy(j2)[i]) / 2 }
        func distPx(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double { let dx = (ax-bx)*s.w, dy = (ay-by)*s.h; return (dx*dx+dy*dy).squareRoot() }

        let shoulderWpx = distPx(s.jx(.leftShoulder)[a], s.jy(.leftShoulder)[a], s.jx(.rightShoulder)[a], s.jy(.rightShoulder)[a])
        let torsoPx = distPx(midX(.leftShoulder, .rightShoulder, a), midY(.leftShoulder, .rightShoulder, a), midX(.leftHip, .rightHip, a), midY(.leftHip, .rightHip, a))
        let cmPerPx = angle == .dtl ? 50.0 / max(torsoPx, 1) : 40.0 / max(shoulderWpx, 1)
        func inch(_ px: Double) -> Double { (px * cmPerPx) / 2.54 }

        func headX(_ i: Int) -> Double { s.jx(.nose)[i].isNaN ? midX(.leftEar, .rightEar, i) : s.jx(.nose)[i] }
        func headY(_ i: Int) -> Double { s.jy(.nose)[i].isNaN ? midY(.leftEar, .rightEar, i) : s.jy(.nose)[i] }

        let hx0 = headX(a), hy0 = headY(a)
        m.headRiseCm = r1((headY(imp) - hy0) * s.h * cmPerPx)
        var sway = 0.0; for i in a...max(a,imp) { sway = max(sway, inch(abs(headX(i) - hx0) * s.w)) }
        m.headSwayIn = r1(sway)
        let hip0 = midX(.leftHip, .rightHip, a)
        var pel = 0.0; for i in a...max(a,imp) { pel = max(pel, inch(abs(midX(.leftHip, .rightHip, i) - hip0) * s.w)) }
        m.pelvisSwayIn = r1(pel)

        func spineTilt(_ i: Int) -> Double {
            let dx = (midX(.leftShoulder, .rightShoulder, i) - midX(.leftHip, .rightHip, i)) * s.w
            let dy = (midY(.leftShoulder, .rightShoulder, i) - midY(.leftHip, .rightHip, i)) * s.h
            return abs(atan2(dx, dy) * 180 / .pi)
        }
        m.spineLossDeg = r1(abs(spineTilt(imp) - spineTilt(a)))

        let laX = s.jx(J(lead, "Ankle"))[a], taX = s.jx(J(trail, "Ankle"))[a]
        if abs(laX - taX) > 0.02 { m.weightLeadPctEst = r1(max(0, min(100, (midX(.leftHip, .rightHip, imp) - taX) / (laX - taX) * 100))) }

        func lineAngle(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double { atan2((by-ay)*s.h, (bx-ax)*s.w) * 180 / .pi }
        let shAng = lineAngle(s.jx(.leftShoulder)[top], s.jy(.leftShoulder)[top], s.jx(.rightShoulder)[top], s.jy(.rightShoulder)[top])
        let hipAng = lineAngle(s.jx(.leftHip)[top], s.jy(.leftHip)[top], s.jx(.rightHip)[top], s.jy(.rightHip)[top])
        var xf = abs(shAng - hipAng); if xf > 90 { xf = 180 - xf }; m.xfactorDeg = r1(xf)

        func jointAngle(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ cx: Double, _ cy: Double) -> Double {
            let v1x = (ax-bx)*s.w, v1y = (ay-by)*s.h, v2x = (cx-bx)*s.w, v2y = (cy-by)*s.h
            let d = (v1x*v2x+v1y*v2y) / ((v1x*v1x+v1y*v1y).squareRoot() * (v2x*v2x+v2y*v2y).squareRoot() + 1e-9)
            return acos(max(-1, min(1, d))) * 180 / .pi
        }
        let fps = s.fps > 0 ? s.fps : 30
        let postImpact = min(imp + Int(0.12 * fps), s.n - 1)
        let laA = jointAngle(s.jx(J(lead, "Shoulder"))[postImpact], s.jy(J(lead, "Shoulder"))[postImpact], s.jx(J(lead, "Elbow"))[postImpact], s.jy(J(lead, "Elbow"))[postImpact], s.jx(J(lead, "Wrist"))[postImpact], s.jy(J(lead, "Wrist"))[postImpact])
        m.leadArmBendDeg = r1(max(0, 180 - laA))

        func kneeAngle(_ i: Int) -> Double { jointAngle(s.jx(J(trail, "Hip"))[i], s.jy(J(trail, "Hip"))[i], s.jx(J(trail, "Knee"))[i], s.jy(J(trail, "Knee"))[i], s.jx(J(trail, "Ankle"))[i], s.jy(J(trail, "Ankle"))[i]) }
        m.trailKneeFlexLossDeg = r1(max(0, kneeAngle(top) - kneeAngle(a)))

        let tempoNum = events.top.t - events.address.t, tempoDen = events.impact.t - events.top.t
        if tempoNum > 0 && tempoDen > 0 { m.tempoRatio = r1(tempoNum / tempoDen) }
        return m
    }
}

private func r1(_ v: Double) -> Double? { v.isFinite ? (v*10).rounded()/10 : nil }
