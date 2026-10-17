import XCTest

/// Scripted walkthrough for the demo video. Paced for a viewer, not for speed.
/// Uses a sample runner (no personal data) and the on-device model.
/// Run with: -only-testing:OpenStrideUITests/DemoRecordingTests
final class DemoRecordingTests: XCTestCase {
    func testDemoWalkthrough() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "overreaching", "-backend", "4b"]
        app.launch()

        print("DEMO_MARK launch \(Date().timeIntervalSince1970)")
        XCTAssertTrue(app.staticTexts["Your coach"].waitForExistence(timeout: 300))
        print("DEMO_MARK plan \(Date().timeIntervalSince1970)")
        sleep(5)

        app.swipeUp()
        sleep(3)
        app.staticTexts["Tempo"].firstMatch.tap()
        sleep(4)
        app.navigationBars.buttons.firstMatch.tap()
        sleep(1)
        app.swipeDown()
        sleep(1)

        app.buttons["Insights"].tap()
        sleep(3)
        for _ in 0..<2 {
            app.swipeUp(velocity: .slow)
            sleep(2)
        }
        app.swipeUp(velocity: .slow)
        sleep(2)
        app.swipeUp(velocity: .slow)
        sleep(1)
        let saw = app.buttons["What the coach saw"].firstMatch
        if saw.exists { saw.tap() }
        sleep(1)
        app.swipeUp(velocity: .slow)
        sleep(4)

        app.buttons["Settings"].tap()
        sleep(4)
        print("DEMO_MARK end \(Date().timeIntervalSince1970)")
    }
}
