import XCTest

/// Real iPhone, real Apple Health, on-device Gemma. Never writes to Health.
/// Run with: -only-testing:OpenStrideUITests/DeviceFlowTests
final class DeviceFlowTests: XCTestCase {
    func testRealHealthOnDeviceGemma() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-backend", "4b"]
        app.launch()

        // Fresh install lands on onboarding with defaults: 10K in 10 weeks, 4 runs, long run Sunday.
        let build = app.buttons["Build my plan"]
        if build.waitForExistence(timeout: 10) {
            attach(app, "onboarding")
            build.tap()
        }

        // Read-only Health sheet.
        let turnOn = app.staticTexts["Turn On All"].firstMatch
        if turnOn.waitForExistence(timeout: 30) {
            turnOn.tap()
            app.buttons["Allow"].firstMatch.tap()
        }

        // First run downloads 2.6 GB of weights, then plans. Take a progress shot along the way.
        let start = Date()
        if app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Downloading'")).firstMatch.waitForExistence(timeout: 60) {
            attach(app, "downloading")
        }
        let coach = app.staticTexts["Your coach"]
        XCTAssertTrue(coach.waitForExistence(timeout: 1800), "no plan after 30 min")
        print("PLAN_READY_AFTER_SECONDS \(Int(Date().timeIntervalSince(start)))")

        // Re-plan: model already loaded, so this times generation alone.
        let replan = app.buttons["Re-plan"]
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: replan)
        waitForExpectations(timeout: 120)
        let t1 = Date()
        replan.tap()
        sleep(2)
        expectation(for: enabled, evaluatedWith: replan)
        waitForExpectations(timeout: 600)
        print("REPLAN_SECONDS \(Int(Date().timeIntervalSince(t1)))")
        attach(app, "week")
        app.swipeUp()
        attach(app, "week-2")

        app.buttons["Insights"].tap()
        sleep(1)
        attach(app, "insights-1")
        for i in 2...5 {
            app.swipeUp()
            attach(app, "insights-\(i)")
        }
        let saw = app.buttons["What the coach answered"].firstMatch
        if saw.exists {
            saw.tap()
            app.swipeUp()
            attach(app, "insights-raw")
        }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
