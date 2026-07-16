// Part of Divot (built + tested; see App/DivotApp.swift).
import Foundation
import CoreHaptics
import SwingCore
import os.log

private let hapticsLog = Logger(subsystem: "com.rboyarov91.divot", category: "haptics")

/// P2.5 — play the measured tempo back as two haptic beats (top + impact).
/// Pure timing comes from the engine (HapticBeats); firing is device-only (Simulator has no haptics).
enum TempoHaptics {
    /// Relative beat offsets (seconds) for a swing — 2 beats, top then impact. Testable without hardware.
    static func beats(for swing: SwingAnalysis) -> [Double] { HapticBeats.offsets(swing.events) }

    static var isSupported: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }
}

/// Owns a CHHapticEngine and plays a tempo pattern. No-op where haptics are unsupported.
final class HapticsPlayer {
    private var engine: CHHapticEngine?

    func play(offsets: [Double]) {
        guard TempoHaptics.isSupported, !offsets.isEmpty else { return }
        do {
            if engine == nil { engine = try CHHapticEngine() }
            try engine?.start()
            let events = offsets.map { t in
                CHHapticEvent(eventType: .hapticTransient,
                              parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                           CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7)],
                              relativeTime: t)
            }
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine?.makePlayer(with: pattern)
            try player?.start(atTime: 0)
        } catch {
            // Haptics are a non-critical enhancement — a failure here shouldn't surface to the
            // user, but silently swallowing it made a bad engine/pattern state invisible even
            // during debugging (finding Low). Log, don't propagate.
            hapticsLog.error("haptics playback failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
