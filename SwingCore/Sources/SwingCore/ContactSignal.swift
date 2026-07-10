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
    public static func evaluate(ballAtAddress: CGPoint?, flightDetected: Bool,
                                 ballStillAtAddressSpot: Bool) -> ContactSignal {
        guard ballAtAddress != nil else {
            return ContactSignal(likelyContact: true, reason: "no ball detected — not evaluated")
        }
        if flightDetected {
            return ContactSignal(likelyContact: true, reason: "ball flight traced")
        }
        if ballStillAtAddressSpot {
            return ContactSignal(likelyContact: false, reason: "no contact detected")
        }
        return ContactSignal(likelyContact: true, reason: "ambiguous — assumed contact")
    }
}
