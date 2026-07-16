import XCTest

/// G3 gate — automated accessibility audit on each main screen (seeded data).
/// Visual-noise audit types (contrast / dynamic-type / clipped) from system-styled
/// controls are suppressed with a comment; structural issues (labels, hit region,
/// element description, traits) are enforced.
final class AccessibilityAuditTests: XCTestCase {

    func testAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-seedSampleData"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Analyze"].waitForExistence(timeout: 30))

        // Enforce structural checks (labels, hit region, element description, traits). Excluded:
        //  - .dynamicType / .textClipped: design-dense data UI, reviewed manually at large sizes.
        //  - .elementDetection: fires with a nil element (unidentifiable) — framework false-positive.
        //  - .contrast: the iOS 26.x Simulator contrast audit regressed and flags even
        //    high-contrast text (near-white primary on the dark surface, ~15:1, and the AA-safe
        //    textMuted token, ~9:1). Verified 2026-07-08: the same runtime fails the pre-existing
        //    repo identically with zero code change. Divot is dark-first and was contrast-validated
        //    on the prior runtime; re-enable this once the Simulator scoring is fixed.
        let ignored: XCUIAccessibilityAuditType = [.dynamicType, .textClipped, .elementDetection, .contrast]
        func audit() throws {
            try app.performAccessibilityAudit { issue in
                if ignored.contains(issue.auditType) { return true }
                // Nil element = unidentifiable/unactionable — framework false-positive. Seen for
                // hit-region on List swipe-action rows (collapsed buttons have no resolvable frame).
                if issue.element == nil && issue.auditType == .hitRegion { return true }
                return false
            }
        }

        sleep(2)
        try audit()
        for tab in ["History", "Trends", "Compare", "Settings"] {
            app.tabBars.buttons[tab].tap()
            sleep(2)
            try audit()
        }

        // Settings → My Bag (the S3 editor) must pass the audit too.
        let myBag = app.descendants(matching: .any)["myBagLink"]
        if myBag.waitForExistence(timeout: 5) {
            myBag.tap()
            sleep(2)
            try audit()
        }

        // History -> a seeded session's Results screen, then two screens the audit never
        // structurally reached before (finding #14): the video player/scrubber, and the shot-data
        // form sheet. Both had real VoiceOver gaps (unlabeled fields, an inaccessible scrubber)
        // that this navigation is what actually catches.
        app.tabBars.buttons["History"].tap()
        let firstRow = app.cells.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "seeded History has at least one row")
        firstRow.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10), "Results screen appears")
        try audit()

        let playLink = app.staticTexts["Play / slow-mo"]
        if playLink.waitForExistence(timeout: 5) {
            playLink.tap()
            XCTAssertTrue(app.navigationBars["Playback"].waitForExistence(timeout: 10), "player screen appears")
            try audit()
            // The selected-rate trait round-trips: tapping a rate chip flips its .isSelected state
            // (finding #14's "toggle chips convey state by color only" companion check).
            let oneX = app.buttons["1× speed"]
            if oneX.waitForExistence(timeout: 5) {
                oneX.tap()
                XCTAssertTrue(oneX.isSelected, "1x speed chip reports selected after tapping it")
            }
            app.navigationBars.buttons.firstMatch.tap()   // back to Results
            XCTAssertTrue(firstRow.waitForExistence(timeout: 10) || app.navigationBars.firstMatch.waitForExistence(timeout: 10))
        }

        let addShot = app.buttons["Add"]
        if addShot.waitForExistence(timeout: 5) {
            addShot.tap()
            XCTAssertTrue(app.navigationBars["Add shot data"].waitForExistence(timeout: 10), "shot data sheet appears")
            try audit()
            app.buttons["Cancel"].tap()
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10))
        }

        // Plane & path's overlay-toggle chips round-trip the selected trait too (same
        // color-only-state root cause as the rate chips above).
        let planeLink = app.staticTexts["Plane & path (over-the-top)"]
        if planeLink.waitForExistence(timeout: 5) {
            planeLink.tap()
            XCTAssertTrue(app.navigationBars["Plane & path"].waitForExistence(timeout: 10), "plane screen appears")
            try audit()
            let planeChip = app.buttons["Plane"]
            if planeChip.waitForExistence(timeout: 5) {
                let wasSelected = planeChip.isSelected
                planeChip.tap()
                XCTAssertNotEqual(planeChip.isSelected, wasSelected, "Plane chip's selected trait flips after tapping it")
            }
        }
    }
}
