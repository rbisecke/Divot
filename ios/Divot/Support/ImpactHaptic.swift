// D3 — pure predicate for the "impact-frame" haptic while scrubbing playback.
// Fires once as the playhead crosses the impact time, not repeatedly.
import Foundation
import SwingCore

enum ImpactHaptic {
    /// - Parameters:
    ///   - playhead: current playback time (s)
    ///   - events: detected swing events (uses impact.t)
    ///   - lastFired: the playhead value when the tick last fired (nil if never)
    ///   - window: how close (s) to impact counts as "at impact"
    static func shouldFire(playhead t: Double, events: SwingEvents,
                           lastFired: Double?, window: Double = 0.04) -> Bool {
        let impact = events.impact.t
        guard abs(t - impact) <= window else { return false }
        // Suppress if we already fired for this crossing (last fire was also within the window).
        if let last = lastFired, abs(last - impact) <= window { return false }
        return true
    }
}
