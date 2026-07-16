import XCTest

/// Shared "wait for this screen's real content" helpers for AccessibilityAuditTests and
/// ScreenshotTour, replacing fixed `sleep(N)` delays (Medium finding: a hardcoded sleep can
/// audit/screenshot a still-loading view and report green while missing real issues in the
/// fully-rendered state — a slower render than the hardcoded duration silently passes anyway).
enum UITestWait {
    /// Generic per-tab/screen readiness: the navigation bar with this exact title has appeared.
    @discardableResult
    static func navigationTitle(_ app: XCUIApplication, _ title: String, timeout: TimeInterval = 10) -> Bool {
        app.navigationBars[title].waitForExistence(timeout: timeout)
    }

    /// Any navigation bar (for screens whose title is dynamic, e.g. Results is the club name).
    @discardableResult
    static func anyNavigationBar(_ app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        app.navigationBars.firstMatch.waitForExistence(timeout: timeout)
    }

    /// History specifically waits for a seeded row rather than just the nav bar, since the
    /// interesting content is the list (matches the already-correct pattern ScreenshotTour used
    /// for its own History screenshot).
    @discardableResult
    static func historyRows(_ app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        app.cells.firstMatch.waitForExistence(timeout: timeout)
    }

    /// Waits for a specific element (by label) to exist — used where a screen's readiness is
    /// better signaled by a particular piece of content than by the nav bar alone (e.g. a button
    /// far down a scrollable Results screen, after a swipe).
    @discardableResult
    static func element(_ el: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        el.waitForExistence(timeout: timeout)
    }
}
