import Foundation

// P2.5 (pure slice) — tempo haptics timing. Relative offsets (seconds from address)
// for a top-of-backswing beat and an impact beat, preserving the backswing:downswing
// ratio. Pure so it's validated headlessly; Core Haptics plays these on device.

public enum HapticBeats {
    /// [topOffset, impactOffset] in seconds from the address baseline.
    public static func offsets(_ events: SwingEvents) -> [Double] {
        let base = events.address.t
        let top = Swift.max(0, events.top.t - base)
        let impact = Swift.max(top, events.impact.t - base)
        return [top, impact]
    }
}
