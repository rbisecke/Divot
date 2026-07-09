import XCTest
@testable import Divot
import SwingCore

/// Wave 3 pure-logic tests (haptic predicate, reduce-motion fallback, tip eligibility).
final class Wave3Tests: XCTestCase {

    private func events(impact: Double) -> SwingEvents {
        SwingEvents(address: SwingEvent(t: 0, frame: 0),
                    top: SwingEvent(t: impact - 0.4, frame: 12),
                    impact: SwingEvent(t: impact, frame: 48),
                    finish: SwingEvent(t: impact + 0.6, frame: 66))
    }

    func testImpactHapticPredicate() {
        let e = events(impact: 1.60)
        // far from impact → no fire
        XCTAssertFalse(ImpactHaptic.shouldFire(playhead: 1.0, events: e, lastFired: nil))
        // crossing impact, never fired → fire
        XCTAssertTrue(ImpactHaptic.shouldFire(playhead: 1.61, events: e, lastFired: nil))
        // still near impact but already fired this crossing → suppress
        XCTAssertFalse(ImpactHaptic.shouldFire(playhead: 1.62, events: e, lastFired: 1.61))
        // left the window and came back (lastFired far away) → fire again
        XCTAssertTrue(ImpactHaptic.shouldFire(playhead: 1.59, events: e, lastFired: 1.0))
    }

    func testReduceMotionFallback() {
        XCTAssertTrue(MotionPreference.usesPlainTransition(reduceMotion: true))
        XCTAssertFalse(MotionPreference.usesPlainTransition(reduceMotion: false))
    }

    func testTipEligibility() {
        // Not used enough yet → hidden.
        XCTAssertFalse(TipGate(timesShown: 0, usageEvents: 0).shouldShow)
        // Used once, never shown → show.
        XCTAssertTrue(TipGate(timesShown: 0, usageEvents: 1).shouldShow)
        // Already shown the max → hidden (show-once).
        XCTAssertFalse(TipGate(timesShown: 1, usageEvents: 5).shouldShow)
    }
}
