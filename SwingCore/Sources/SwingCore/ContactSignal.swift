import Foundation
import CoreGraphics

// P3.5 — best-effort, on-device "was the ball actually struck" signal, used only to soft-
// label a clip in History (never to withhold a save — see EXPERIMENTAL.md-style enable bar
// below). Combines two already-built, best-effort detectors (BallDetector, BallFlightTracer);
// adds no new detection of its own.

public struct ContactSignal: Codable, Sendable, Equatable {
    public let likelyContact: Bool
    public let reason: String   // short, user-facing: shown as the History label when false

    public init(likelyContact: Bool, reason: String) {
        self.likelyContact = likelyContact
        self.reason = reason
    }
}

public enum ContactEvaluator {
    /// `ballAtAddress`: BallDetector's find on the address frame, if any.
    /// `flightDetected`: BallFlightTracer found a post-impact trajectory.
    /// `ballStillAtAddressSpot`: a fresh BallDetector pass on a post-impact frame still finds
    /// a ball blob within a small radius of `ballAtAddress` (i.e., it never moved).
    /// `audioTransientAtImpact`: P3.6 — AudioImpactDetector found its strongest transient
    /// within tolerance of the detected impact frame. Independent of the vision signals above
    /// (doesn't need a ball to have been found at all), so it's OR'd in afterward rather than
    /// folded into the vision-only branches: either signal firing is enough to call contact,
    /// matching the same default-to-true, soft-label bias this evaluator already encodes.
    public static func evaluate(ballAtAddress: CGPoint?, flightDetected: Bool,
                                 ballStillAtAddressSpot: Bool,
                                 audioTransientAtImpact: Bool = false) -> ContactSignal {
        let visual: ContactSignal
        if ballAtAddress == nil {
            visual = ContactSignal(likelyContact: true, reason: "no ball detected — not evaluated")
        } else if flightDetected {
            visual = ContactSignal(likelyContact: true, reason: "ball flight traced")
        } else if ballStillAtAddressSpot {
            visual = ContactSignal(likelyContact: false, reason: "no contact detected")
        } else {
            visual = ContactSignal(likelyContact: true, reason: "ambiguous — assumed contact")
        }

        guard audioTransientAtImpact else { return visual }
        if visual.reason == "ball flight traced" {
            return ContactSignal(likelyContact: true, reason: "ball flight traced & audio transient at impact")
        }
        return ContactSignal(likelyContact: true, reason: "audio transient at impact")
    }
}
