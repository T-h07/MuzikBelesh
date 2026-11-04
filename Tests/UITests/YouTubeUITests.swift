import XCTest

final class YouTubeUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        app = XCUIApplication()
        app.launchEnvironment["MB_UI_TEST_ID"] = UUID().uuidString
        app.launchArguments = ["--ui-testing", "--reset-ui-library", "--youtube-fixtures"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Search"].waitForExistence(timeout: 10))
    }
    override func tearDownWithError() throws { app?.terminate() }
    private func youtubeSearch() {
        app.tabBars.buttons["Search"].tap()
        app.segmentedControls.buttons["YouTube"].tap()
    }
    private func inspect(_ value: String) {
        let field = app.textFields["youtube-link-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 3)); field.tap(); field.typeText(value)
        app.buttons["youtube-inspect-link"].tap()
    }
    func testSearchPaginationDetailsPreparationAndBackNavigation() {
        youtubeSearch()
        let field = app.textFields["search-field"]
        field.tap(); field.typeText("fixture\n")
        let first = app.buttons["youtube-result-9bZkp7q19f0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        app.buttons["youtube-load-more"].tap()
        XCTAssertTrue(app.buttons["youtube-result-dQw4w9WgXcQ"].waitForExistence(timeout: 3))
        first.tap()
        XCTAssertTrue(app.staticTexts["youtube-stream-ready"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["youtube-detail-title"].label, "Resolved Fixture Song")
        XCTAssertEqual(app.staticTexts["youtube-library-status"].label, "Not Downloaded")
        let prepare = app.buttons["youtube-prepare"]
        if !prepare.isHittable { app.swipeUp() }
        prepare.tap()
        XCTAssertTrue(app.staticTexts["youtube-prepared"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["youtube-prepared"].label.contains("Nothing has been downloaded"))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        XCTAssertTrue(app.tabBars.buttons["Library"].isHittable)
    }
    func testValidPastedLinkUsesSameDetailsAndCanReturn() {
        youtubeSearch(); app.buttons["youtube-paste-link"].tap()
        inspect("https://m.youtube.com/watch?v=9bZkp7q19f0&si=fixture&list=anything")
        XCTAssertTrue(app.staticTexts["youtube-stream-ready"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["youtube-detail-title"].label, "Resolved Fixture Song")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.textFields["youtube-link-input"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["youtube-paste-link"].waitForExistence(timeout: 3))
    }
    func testMalformedLinkShowsValidationErrorWithoutOpeningDetails() {
        youtubeSearch(); app.buttons["youtube-paste-link"].tap()
        inspect("https://youtube.com.attacker.example/watch?v=9bZkp7q19f0")
        XCTAssertTrue(app.staticTexts["youtube-link-error"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["youtube-detail-title"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.tabBars.buttons["Library"].isHittable)
    }
    func testYouTubeSearchAndDetailsPreserveLocalPlayback() {
        app.tabBars.buttons["Library"].tap()
        app.buttons["library-filter-Songs"].tap()
        let track = app.staticTexts["Fixture A"].firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 5)); track.tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        youtubeSearch()
        let field = app.textFields["search-field"]
        field.tap(); field.typeText("fixture\n")
        let result = app.buttons["youtube-result-9bZkp7q19f0"]
        XCTAssertTrue(result.waitForExistence(timeout: 5)); result.tap()
        XCTAssertTrue(app.staticTexts["youtube-stream-ready"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pause"].exists)
        XCTAssertTrue(app.staticTexts["Fixture A"].firstMatch.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Pause"].isHittable)
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["Pause"].isHittable)
    }
}
