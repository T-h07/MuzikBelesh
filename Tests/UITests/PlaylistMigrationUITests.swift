import XCTest

final class PlaylistMigrationUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["MB_UI_TEST_ID"] = UUID().uuidString
        app.launchArguments = ["--ui-testing", "--reset-ui-library", "--migration-fixtures"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10))
    }
    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 {
            let evidence = XCTAttachment(screenshot: app.screenshot()); evidence.lifetime = .keepAlways; add(evidence)
            let tree = XCTAttachment(string: app.debugDescription); tree.lifetime = .keepAlways; add(tree)
        }
        app.terminate()
    }
    private func open(_ name: String) {
        app.tabBars.buttons["Library"].tap()
        let filter = app.buttons["library-filter-Playlists"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5)); filter.tap()
        let playlist = app.staticTexts[name]; XCTAssertTrue(playlist.waitForExistence(timeout: 5)); playlist.tap()
        XCTAssertTrue(app.staticTexts["migration-playlist-count"].waitForExistence(timeout: 5))
    }
    func testFiveHundredPlaceholdersRemainVisibleAcrossRelaunch() {
        open("Imported placeholders")
        XCTAssertEqual(app.staticTexts["migration-playlist-count"].label, "500 songs • 0 available offline")
        XCTAssertFalse(app.buttons["collection-play"].isEnabled)
        XCTAssertFalse(app.buttons["playlist-add-songs"].exists); XCTAssertFalse(app.buttons["playlist-reorder"].exists)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Original song 0"].exists)
        XCTAssertTrue(app.staticTexts["Original artist"].firstMatch.exists)
        app.terminate(); app.launchArguments = ["--ui-testing", "--migration-fixtures"]; app.launch()
        open("Imported placeholders")
        XCTAssertEqual(app.staticTexts["migration-playlist-count"].label, "500 songs • 0 available offline")
        XCTAssertFalse(app.buttons["collection-play"].isEnabled)
    }
    func testMixedOccurrencesShowSourceCountAndDistinctRows() {
        open("Imported mixed")
        XCTAssertEqual(app.staticTexts["migration-playlist-count"].label, "5 songs • 3 available offline")
        XCTAssertTrue(app.buttons["collection-play"].isEnabled)
        app.swipeUp()
        let first = app.staticTexts["Original song 0"], second = app.staticTexts["Original song 1"]
        XCTAssertTrue(first.exists); XCTAssertTrue(second.exists)
        XCTAssertLessThan(first.frame.minY, second.frame.minY)
        XCTAssertTrue(app.staticTexts["Awaiting local audio"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Available offline"].firstMatch.exists)
    }
}
