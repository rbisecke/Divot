// D2 — reduce-motion gating for the History→playback zoom transition.
import Foundation

enum MotionPreference {
    /// True when we should use the plain (non-zoom) navigation transition.
    static func usesPlainTransition(reduceMotion: Bool) -> Bool { reduceMotion }
}
