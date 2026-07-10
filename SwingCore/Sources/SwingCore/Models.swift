import Foundation
import CoreGraphics

// MARK: - Enums

public enum Angle: String, Codable, Sendable { case faceOn = "face_on", dtl }
public enum Hand: String, Codable, Sendable { case right = "R", left = "L" }

// ClubCategory + ClubSpec + Bag live in ClubModel.swift (S1 — open bag model).

/// Vision body-pose joints we track (subset of VNHumanBodyPoseObservation.JointName).
public enum Joint: String, Codable, CaseIterable, Sendable {
    case nose, leftEye, rightEye, leftEar, rightEar, neck
    case leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle, root
}

/// Swing phases (subset of the 8 GolfDB events we compute).
public enum Phase: String, Codable, CaseIterable, Sendable { case address, top, impact, finish }

// MARK: - Geometry

/// A detected joint: normalized coordinates (0…1, origin bottom-left, Vision convention) + confidence.
public struct JointPoint: Codable, Sendable {
    public var x: Double, y: Double, c: Double
    public init(x: Double, y: Double, c: Double) { self.x = x; self.y = y; self.c = c }
}

// MARK: - Pose

public struct PoseFrame: Codable, Sendable {
    public var t: Double
    public var joints: [Joint: JointPoint]
    public init(t: Double, joints: [Joint: JointPoint]) { self.t = t; self.joints = joints }
}

public struct PoseSequence: Codable, Sendable {
    public var fps: Double
    public var width: Int
    public var height: Int
    public var frames: [PoseFrame]
    public init(fps: Double, width: Int, height: Int, frames: [PoseFrame]) {
        self.fps = fps; self.width = width; self.height = height; self.frames = frames
    }
    public var framesDetected: Int { frames.filter { !$0.joints.isEmpty }.count }
}

// MARK: - Events / metrics / faults

public struct SwingEvent: Codable, Sendable {
    public var t: Double; public var frame: Int
    public init(t: Double, frame: Int) { self.t = t; self.frame = frame }
}

public struct SwingEvents: Codable, Sendable {
    public var address: SwingEvent, top: SwingEvent, impact: SwingEvent, finish: SwingEvent
    public init(address: SwingEvent, top: SwingEvent, impact: SwingEvent, finish: SwingEvent) {
        self.address = address; self.top = top; self.impact = impact; self.finish = finish
    }
}

/// The 9 biomechanical metrics (nil = not measurable from this angle / low confidence).
public struct SwingMetrics: Codable, Sendable {
    public var headSwayIn: Double?
    public var headRiseCm: Double?
    public var spineLossDeg: Double?
    public var pelvisSwayIn: Double?
    public var weightLeadPctEst: Double?
    public var tempoRatio: Double?
    public var xfactorDeg: Double?
    public var leadArmBendDeg: Double?
    public var trailKneeFlexLossDeg: Double?
    public init() {}
    public subscript(key: String) -> Double? {
        switch key {
        case "head_sway_in": return headSwayIn
        case "head_rise_cm": return headRiseCm
        case "spine_loss_deg": return spineLossDeg
        case "pelvis_sway_in": return pelvisSwayIn
        case "weight_lead_pct_est": return weightLeadPctEst
        case "tempo_ratio": return tempoRatio
        case "xfactor_deg": return xfactorDeg
        case "lead_arm_bend_deg": return leadArmBendDeg
        case "trail_knee_flex_loss_deg": return trailKneeFlexLossDeg
        default: return nil
        }
    }
}

public struct Fault: Codable, Sendable, Identifiable {
    public var id: String { code + metric }
    public var code: String, label: String, metric: String
    public var value: Double, threshold: Double, severity: Double
    public var cue: String, drill: String
}

// MARK: - Reference / comparison

public struct Template: Codable, Sendable {
    public var club: String, view: String, source: String
    /// Normalized (hip-centered, shoulder-scaled) joint positions per phase.
    public var phases: [Phase: [Joint: CGPoint]]
    public var metrics: SwingMetrics
}

public struct Comparison: Codable, Sendable {
    public var deltas: [String: Double]
    public var perPhaseMatch: [Phase: Double]
    public var overall: Double
}

// MARK: - Results

public struct SwingAnalysis: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var index: Int
    public var events: SwingEvents
    public var metrics: SwingMetrics
    public var faults: [Fault]
    public var comparison: Comparison?
    // C1–C5 club-path additions (all optional; older sessions decode unchanged).
    public var plane: PlaneAnalysis?
    public var ball: CGPoint?
    public var clubHeadPath: ClubHeadPath?
    public var ballFlight: BallFlight?
    public var contact: ContactSignal?   // P3.5, alongside the existing C1–C5 optional fields
    public init(index: Int, events: SwingEvents, metrics: SwingMetrics, faults: [Fault],
                comparison: Comparison? = nil, plane: PlaneAnalysis? = nil, ball: CGPoint? = nil,
                clubHeadPath: ClubHeadPath? = nil, ballFlight: BallFlight? = nil, contact: ContactSignal? = nil) {
        self.index = index; self.events = events; self.metrics = metrics; self.faults = faults
        self.comparison = comparison; self.plane = plane; self.ball = ball
        self.clubHeadPath = clubHeadPath; self.ballFlight = ballFlight; self.contact = contact
    }
}

public struct SessionStats: Codable, Sendable {
    public var bestSwing: Int
    public var recurringFaults: [String: Int]
    public var focus: String
    public init(bestSwing: Int, recurringFaults: [String: Int], focus: String) {
        self.bestSwing = bestSwing; self.recurringFaults = recurringFaults; self.focus = focus
    }
}

public struct Session: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var date: Date
    public var club: ClubSpec
    public var angle: Angle
    public var hand: Hand
    public var swings: [SwingAnalysis]
    public var stats: SessionStats?
    public init(date: Date, club: ClubSpec, angle: Angle, hand: Hand, swings: [SwingAnalysis], stats: SessionStats? = nil) {
        self.date = date; self.club = club; self.angle = angle; self.hand = hand; self.swings = swings; self.stats = stats
    }
}
