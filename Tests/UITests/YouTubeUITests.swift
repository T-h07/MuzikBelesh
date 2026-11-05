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
    func testLongPageClearsMiniPlayerAndLoadsNextPage() {
        app.tabBars.buttons["Library"].tap()
        app.buttons["library-filter-Songs"].tap()
        app.staticTexts["Fixture A"].firstMatch.tap()
        let player = app.buttons["Open Now Playing"]
        XCTAssertTrue(player.waitForExistence(timeout: 5))
        let scroll = app.scrollViews.firstMatch
        for tab in ["Home", "Downloads", "Search"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(scroll.waitForExistence(timeout: 5))
            XCTAssertLessThanOrEqual(scroll.frame.maxY, player.frame.minY, tab)
        }
        app.segmentedControls.buttons["YouTube"].tap()
        let field = app.textFields["search-field"]
        field.tap()
        field.typeText("long page\n")
        XCTAssertTrue(app.buttons["youtube-result-fixture0001"].waitForExistence(timeout: 5))
        let more = app.buttons["youtube-load-more"]
        for _ in 0..<6 {
            if more.exists && more.isHittable && scroll.frame.contains(more.frame) { break }
            scroll.swipeUp()
        }
        let last = app.buttons["youtube-result-fixture0016"]
        XCTAssertTrue(scroll.frame.contains(last.frame))
        XCTAssertTrue(scroll.frame.contains(more.frame))
        XCTAssertGreaterThanOrEqual(more.frame.height, 44)
        XCTAssertLessThanOrEqual(more.frame.maxY, player.frame.minY)
        XCTAssertTrue(more.isHittable)
        more.tap()
        scroll.swipeUp()
        let next = app.buttons["youtube-result-dQw4w9WgXcQ"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertTrue(scroll.frame.contains(next.frame))
        next.tap()
        XCTAssertTrue(app.staticTexts["youtube-stream-ready"].waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(scroll.frame.maxY, player.frame.minY)
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
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
