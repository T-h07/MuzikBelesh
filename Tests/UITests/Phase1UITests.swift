import XCTest

final class Phase1UITests: XCTestCase {
    func testFourTabNavigationSmoke() {
        // An isolated, reset library (which includes a local profile) instead of the
        // simulator's real container, which would show Phase 11.1 onboarding on a fresh device.
        let app = XCUIApplication()
        app.launchEnvironment["MB_UI_TEST_ID"] = UUID().uuidString
        app.launchArguments = ["--ui-testing", "--reset-ui-library"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.staticTexts["Search"].waitForExistence(timeout: 2))
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 2))
        app.tabBars.buttons["Downloads"].tap()
        XCTAssertTrue(app.staticTexts["Downloads"].waitForExistence(timeout: 2))
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["Muzik Belesh"].waitForExistence(timeout: 2))
    }
}

