import XCTest

/// End to end on the simulator: seed Apple Health with a sample runner, grant access,
/// read it back through the real HealthKit path, plan with the coach, check the screens.
final class HealthFlowTests: XCTestCase {
    func testSeededHealthProducesPlan() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-seedHealth", "hr_drift", "-backend", "4b"]
        app.launch()

        // Two Health sheets: write access for the seeder, then read access for the provider.
        for _ in 0..<2 {
            let turnOn = app.staticTexts["Turn On All"].firstMatch
            if turnOn.waitForExistence(timeout: 20) {
                turnOn.tap()
                app.buttons["Allow"].firstMatch.tap()
            }
        }

        let coach = app.staticTexts["Your coach"]
        XCTAssertTrue(coach.waitForExistence(timeout: 180), "no coach card")
        attach(app, "week")

        app.buttons["Insights"].tap()
        XCTAssertTrue(app.staticTexts["Signals"].waitForExistence(timeout: 10))
        attach(app, "insights")
        app.swipeUp()
        attach(app, "insights-2")
        app.swipeUp()
        attach(app, "insights-3")
    }

    /// Sample runner who doubled their mileage: the coach should cut volume and explain the load ratio.
    func testOverreachingDemo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "overreaching", "-backend", "4b"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Your coach"].waitForExistence(timeout: 180), "no coach card")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '1.98'")).firstMatch.exists, "note should cite the load ratio")
        attach(app, "demo-week")

        app.staticTexts["Tempo"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Workout"].waitForExistence(timeout: 5))
        attach(app, "demo-session")
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["Insights"].tap()
        attach(app, "demo-insights")
        app.swipeUp(); app.swipeUp(); app.swipeUp()
        let saw = app.buttons["What the coach saw"].firstMatch
        if saw.exists { saw.tap() }
        attach(app, "demo-coach-saw")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
