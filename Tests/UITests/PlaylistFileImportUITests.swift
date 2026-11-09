import XCTest

final class PlaylistFileImportUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { app?.terminate() }
    private func launch(fixture: Bool) {
        app = XCUIApplication()
        app.launchEnvironment["MB_UI_TEST_ID"] = UUID().uuidString
        app.launchArguments = ["--ui-testing", "--reset-ui-library"] + (fixture ? ["--playlist-import-fixture"] : [])
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10)); app.tabBars.buttons["Library"].tap()
        let filter = app.buttons["library-filter-Playlists"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5)); filter.tap()
        let entry = app.buttons["import-spotify-playlist"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
    }
    func testFilesPickerPresentsAndCancelsWithoutImport() {
        launch(fixture: false)
        let choose = app.buttons["playlist-import-choose-file"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); choose.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.tap()
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["playlist-import-success"].exists)
    }
    func testReviewCommitAndFiveHundredPlaceholders() {
        launch(fixture: true)
        let counts = app.staticTexts["playlist-import-counts"]
        XCTAssertTrue(counts.waitForExistence(timeout: 10)); XCTAssertEqual(counts.label, "1 valid • 0 invalid playlists")
        let confirm = app.buttons["playlist-import-confirm"]
        for _ in 0..<4 where !confirm.isHittable { app.swipeUp() }
        XCTAssertTrue(confirm.isHittable); confirm.tap()
        let open = app.buttons["playlist-import-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        let count = app.staticTexts["migration-playlist-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5)); XCTAssertEqual(count.label, "500 songs • 0 available offline")
        XCTAssertFalse(app.buttons["collection-play"].isEnabled)
    }
}
