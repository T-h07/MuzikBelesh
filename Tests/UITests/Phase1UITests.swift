import XCTest

final class Phase1UITests: XCTestCase {
    func testFourTabNavigationSmoke() {
        let app = XCUIApplication()
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

