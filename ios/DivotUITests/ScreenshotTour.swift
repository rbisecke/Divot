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
        sleep(3)                    // let the results + video-derived sequence strip render
        shot("03-results-top")
        app.swipeUp(); sleep(1)
        shot("04-results-mid")
        app.swipeUp(); sleep(1)
        shot("05-results-bottom")
        if app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }

        app.tabBars.buttons["Trends"].tap()
        sleep(2)
        shot("06-trends")

        app.tabBars.buttons["Compare"].tap()
        sleep(1)
        shot("07-compare")

        app.tabBars.buttons["Settings"].tap()
        sleep(1)
        shot("08-settings")
    }
}
