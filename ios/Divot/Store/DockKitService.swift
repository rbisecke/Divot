// Part of Divot (built + tested; see App/DivotApp.swift).
// ⚠️ EXPERIMENTAL, HARDWARE-ONLY. No-ops without a connected DockKit accessory.
import Foundation
#if canImport(DockKit)
import DockKit
#endif

/// P3.4 — optional motorized-stand (gimbal) tracking to auto-follow the golfer, hands-free.
/// Minimal wiring only; the accessory must be connected at runtime. No-op otherwise.
enum DockKitService {
    /// Whether DockKit is available in this build/OS. Actual tracking also needs a paired accessory.
    static var isSupported: Bool {
        #if canImport(DockKit)
        return true
        #else
        return false
        #endif
    }

    static var statusText: String {
        isSupported ? "DockKit available — connect a motorized stand to auto-follow."
                    : "DockKit not available on this build."
    }
}
