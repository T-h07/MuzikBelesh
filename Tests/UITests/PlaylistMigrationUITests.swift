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
        attachFailureEvidence(app)
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
        executionTimeAllowance = 120 // Includes a relaunch (49 s of 60 in CI #23); capped at 120 s.
        open("Imported placeholders")
        XCTAssertEqual(app.staticTexts["migration-playlist-count"].label, "500 imported • 0 manually added • 500 total • 0 available offline")
        XCTAssertFalse(app.buttons["collection-play"].isEnabled)
        // Hybrid playlists (80bdeba): songs can be added manually to an imported playlist,
        // but its source order is preserved, so it is never reorderable.
        XCTAssertTrue(app.buttons["playlist-add-songs"].exists); XCTAssertFalse(app.buttons["playlist-reorder"].exists)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Original song 0"].exists)
        XCTAssertTrue(app.staticTexts["Original artist"].firstMatch.exists)
        app.terminate(); app.launchArguments = ["--ui-testing", "--migration-fixtures"]; app.launch()
        open("Imported placeholders")
        XCTAssertEqual(app.staticTexts["migration-playlist-count"].label, "500 imported • 0 manually added • 500 total • 0 available offline")
        XCTAssertFalse(app.buttons["collection-play"].isEnabled)
    }
    func testMixedOccurrencesShowSourceCountAndDistinctRows() {
        open("Imported mixed")
        XCTAssertEqual(app.staticTexts["migration-playlist-count"].label, "5 imported • 0 manually added • 5 total • 3 available offline")
        XCTAssertTrue(app.buttons["collection-play"].isEnabled)
        app.swipeUp()
        let first = app.staticTexts["Original song 0"], second = app.staticTexts["Original song 1"]
        XCTAssertTrue(first.exists); XCTAssertTrue(second.exists)
        XCTAssertLessThan(first.frame.minY, second.frame.minY)
        XCTAssertTrue(app.staticTexts["Awaiting local audio"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Available offline"].firstMatch.exists)
    }
    /// Product contract: imported playlists accept existing local songs as independent
    /// occurrences appended after the Spotify entries, without replacing placeholders.
    func testAddingLocalSongsAppendsOccurrencesAndPersistsAcrossRelaunch() {
        executionTimeAllowance = 120 // Includes a relaunch; capped at 120 s by the workflows.
        open("Imported mixed")
        let count = app.staticTexts["migration-playlist-count"]
        XCTAssertEqual(count.label, "5 imported • 0 manually added • 5 total • 3 available offline")
        app.buttons["playlist-add-songs"].tap()
        // ui-track-a already backs three imported occurrences; adding it again is a new occurrence.
        for id in ["ui-track-b", "ui-track-a"] {
            let row = app.buttons["select-track-" + id]
            XCTAssertTrue(row.waitForExistence(timeout: 5)); XCTAssertTrue(row.isEnabled, "\(id) is selectable"); row.tap()
        }
        app.buttons["playlist-confirm-add"].tap()
        let expected = "5 imported • 2 manually added • 7 total • 5 available offline"
        waitUntil(count, "label == %@", expected, timeout: 5, message: "Manual songs are appended and playable")
        XCTAssertTrue(app.buttons["collection-play"].isEnabled)
        XCTAssertFalse(app.buttons["playlist-reorder"].exists, "Source order stays fixed")
        app.swipeUp()
        let first = app.staticTexts["Original song 0"], second = app.staticTexts["Original song 1"]
        XCTAssertTrue(first.exists); XCTAssertTrue(second.exists)
        XCTAssertLessThan(first.frame.minY, second.frame.minY, "Imported order is unchanged")

        app.terminate(); app.launchArguments = ["--ui-testing", "--migration-fixtures"]; app.launch()
        open("Imported mixed")
        XCTAssertEqual(app.staticTexts["migration-playlist-count"].label, expected, "Additions persist after relaunch")
    }
}
