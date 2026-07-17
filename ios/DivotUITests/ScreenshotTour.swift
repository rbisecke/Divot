import XCTest

/// Launches the app with seeded sample data and captures screenshots of each screen.
/// Screens needing live Vision/camera (ghost overlay, in-app recorder) are not asserted here;
/// this tour covers the data-driven UI that renders fully on the Simulator.
final class ScreenshotTour: XCTestCase {

    func testCaptureScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["-seedSampleData"]
        app.launch()

        func shot(_ name: String) {
            let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            a.name = name
            a.lifetime = .keepAlways
            add(a)
        }

        XCTAssertTrue(app.tabBars.buttons["Analyze"].waitForExistence(timeout: 30))
        shot("01-analyze")

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 30), "seeded rows appear")
        shot("02-history")

        app.cells.firstMatch.tap()
        // Let the results + video-derived sequence strip render: wait for the "Play / slow-mo"
        // link, which only appears once a swing/session was actually found and laid out.
        UITestWait.element(app.staticTexts["Play / slow-mo"])
        shot("03-results-top")
        app.swipeUp()
        UITestWait.element(app.buttons["Plane & path (over-the-top)"])
        shot("04-results-mid")
        app.swipeUp()
        UITestWait.element(app.buttons["Compare to the pro (ghost overlay)"])
        shot("05-results-bottom")
        if app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }

        app.tabBars.buttons["Trends"].tap()
        UITestWait.element(app.staticTexts["Metric"])
        shot("06-trends")

        app.tabBars.buttons["Compare"].tap()
        UITestWait.navigationTitle(app, "Compare")
        shot("07-compare")

        app.tabBars.buttons["Settings"].tap()
        UITestWait.navigationTitle(app, "Settings")
        shot("08-settings")
    }
}
