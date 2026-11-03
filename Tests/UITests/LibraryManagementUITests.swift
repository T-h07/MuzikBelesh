import XCTest

final class LibraryManagementUITests: XCTestCase {
    private var app: XCUIApplication!
    private var identifier = ""
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        identifier = UUID().uuidString
        app = XCUIApplication()
        app.launchEnvironment["MB_UI_TEST_ID"] = identifier
        app.launchArguments = ["--ui-testing", "--reset-ui-library"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10))
    }
    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 {
            screenshot("Failure")
            let tree = XCTAttachment(string: app.debugDescription); tree.name = "Accessibility Tree"; tree.lifetime = .keepAlways; add(tree)
        }
        app?.terminate()
    }
    private func openLibrary(_ filter: String = "Songs") {
        app.tabBars.buttons["Library"].tap()
        let chip = app.buttons["library-filter-" + filter.replacingOccurrences(of: " ", with: "-")]
        if !chip.isHittable { app.scrollViews["library-filters"].swipeRight(); app.scrollViews["library-filters"].swipeRight() }
        for _ in 0..<4 { if chip.isHittable { break }; app.scrollViews["library-filters"].swipeLeft() }
        XCTAssertTrue(chip.waitForExistence(timeout: 5)); chip.tap()
    }
    private func change(_ field: XCUIElement, to text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count)); field.typeText(text)
    }
    private func tapVisible(_ element: XCUIElement) {
        for _ in 0..<5 { if element.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(element.exists); element.tap()
    }
    private func absent(_ element: XCUIElement) {
        let predicate = NSPredicate(format: "exists == false")
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: 8)
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func createPlaylist(_ name: String) {
        openLibrary("Playlists"); app.buttons["create-playlist"].tap()
        change(app.textFields["playlist-name"], to: name)
        change(app.descendants(matching: .any).matching(identifier: "playlist-description").firstMatch, to: "Offline songs")
        app.buttons["playlist-save"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 8))
    }
    private func actions(_ id: String) { tapVisible(app.buttons["track-actions-" + id]) }

    func testLibraryAlbumArtistAndSortingLayouts() {
        openLibrary()
        app.buttons["library-sort"].tap(); app.buttons["Name A–Z"].tap()
        let a = app.buttons["track-actions-ui-track-a"], b = app.buttons["track-actions-ui-track-b"]
        expectation(for: NSPredicate { _, _ in a.exists && b.exists && a.frame.minY < b.frame.minY }, evaluatedWith: app)
        waitForExpectations(timeout: 5); screenshot("Library-Sorted")
        openLibrary("Artists"); app.staticTexts["Fixture Artist"].firstMatch.tap()
        XCTAssertTrue(app.buttons["collection-play"].waitForExistence(timeout: 5)); screenshot("Artist-Detail")
        tapVisible(app.staticTexts["Fixture Album"].firstMatch)
        XCTAssertTrue(app.navigationBars["Album"].waitForExistence(timeout: 5)); screenshot("Album-Detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        createPlaylist("Compact Layout")
        app.staticTexts["Compact Layout"].firstMatch.tap()
        app.buttons["playlist-actions"].tap(); app.buttons["Edit Playlist"].tap()
        XCTAssertTrue(app.textFields["playlist-name"].waitForExistence(timeout: 5)); screenshot("Playlist-Editor")
        app.buttons["Cancel"].tap()
    }

    func testPlaylistCRUDMembershipReorderingAndSafeRemoval() {
        createPlaylist("Road")
        app.staticTexts["Road"].firstMatch.tap()
        app.buttons["playlist-actions"].tap(); app.buttons["Edit Playlist"].tap()
        change(app.textFields["playlist-name"], to: "Road Renamed")
        app.buttons["playlist-save"].tap()
        XCTAssertTrue(app.staticTexts["Road Renamed"].waitForExistence(timeout: 8))
        app.buttons["playlist-add-songs"].tap()
        for id in ["ui-track-a", "ui-track-b", "ui-track-c"] { app.buttons["select-track-" + id].tap() }
        app.buttons["playlist-confirm-add"].tap()
        XCTAssertTrue(app.buttons["playlist-reorder"].waitForExistence(timeout: 8)); app.buttons["playlist-reorder"].tap()
        tapVisible(app.buttons["move-up-ui-track-a"])
        let a = app.buttons["move-up-ui-track-a"]
        let b = app.buttons["move-up-ui-track-b"]
        expectation(for: NSPredicate { _, _ in a.exists && b.exists && a.frame.minY < b.frame.minY }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        screenshot("Playlist-Reordering")
        app.buttons["playlist-reorder"].tap()
        actions("ui-track-a"); app.buttons["Remove from Playlist"].tap()
        absent(app.buttons["track-actions-ui-track-a"])
        app.buttons["playlist-actions"].tap(); app.buttons["Delete Playlist"].tap()
        let confirm = app.buttons["confirm-delete-playlist"]
        if confirm.waitForExistence(timeout: 2) { confirm.tap() } else { app.buttons["Delete Playlist"].firstMatch.tap() }
        XCTAssertTrue(app.staticTexts["No playlists"].waitForExistence(timeout: 8))
        openLibrary()
        for id in ["ui-track-a", "ui-track-b", "ui-track-c"] { XCTAssertTrue(app.buttons["track-actions-" + id].waitForExistence(timeout: 5)) }
        screenshot("Library-After-Playlist-Deletion")
    }

    func testLikeUnlikeIsSharedWithLikedSongs() {
        openLibrary(); actions("ui-track-b"); app.buttons["Like Song"].tap()
        openLibrary("Liked Songs")
        XCTAssertTrue(app.buttons["track-actions-ui-track-b"].waitForExistence(timeout: 5))
        screenshot("Liked-Songs")
        actions("ui-track-b"); app.buttons["Unlike Song"].tap()
        XCTAssertTrue(app.staticTexts["No liked songs"].waitForExistence(timeout: 5))
    }

    func testMetadataSaveCancelAndLocalSearchAcrossAllFields() {
        openLibrary(); actions("ui-track-a"); app.buttons["Edit Metadata"].tap()
        change(app.textFields["metadata-title"], to: "Aurora Edited")
        change(app.textFields["metadata-artist"], to: "Offline Artist")
        change(app.textFields["metadata-album"], to: "Night Album")
        screenshot("Metadata-Editor-Draft")
        app.buttons["metadata-save"].tap()
        XCTAssertTrue(app.staticTexts["Aurora Edited"].waitForExistence(timeout: 8))
        actions("ui-track-a"); app.buttons["Edit Metadata"].tap()
        change(app.textFields["metadata-title"], to: "Unsaved Title"); app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Aurora Edited"].waitForExistence(timeout: 5)); XCTAssertFalse(app.staticTexts["Unsaved Title"].exists)
        app.tabBars.buttons["Search"].tap(); app.buttons["Your Library"].tap()
        for term in ["Aurora Edited", "Offline Artist", "Night Album"] {
            change(app.textFields["search-field"], to: term)
            XCTAssertTrue(app.buttons["track-actions-ui-track-a"].waitForExistence(timeout: 5))
        }
        screenshot("Local-Search")
        app.staticTexts["Aurora Edited"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["mini-player"].waitForExistence(timeout: 5) || app.buttons["Open Now Playing"].waitForExistence(timeout: 5))
    }

    func testDeletionConfirmationCancelAndConfirm() {
        openLibrary(); actions("ui-track-c"); app.buttons["Delete Song"].tap(); app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["track-actions-ui-track-c"].exists)
        actions("ui-track-c"); app.buttons["Delete Song"].tap()
        let confirm = app.buttons["confirm-delete-track"]
        if confirm.waitForExistence(timeout: 2) { confirm.tap() } else { app.buttons["Delete Song"].firstMatch.tap() }
        absent(app.buttons["track-actions-ui-track-c"])
        XCTAssertTrue(app.buttons["track-actions-ui-track-a"].exists); XCTAssertTrue(app.buttons["track-actions-ui-track-b"].exists)
        screenshot("Library-After-Confirmed-Deletion")
    }

    func testRestartRetainsPlaylistMetadataAndLikedState() {
        createPlaylist("Persistent Road")
        openLibrary(); actions("ui-track-a"); app.buttons["Edit Metadata"].tap()
        change(app.textFields["metadata-title"], to: "Persisted Title"); app.buttons["metadata-save"].tap()
        XCTAssertTrue(app.staticTexts["Persisted Title"].waitForExistence(timeout: 8))
        actions("ui-track-a"); app.buttons["Like Song"].tap()
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        openLibrary(); XCTAssertTrue(app.staticTexts["Persisted Title"].waitForExistence(timeout: 8))
        openLibrary("Liked Songs"); XCTAssertTrue(app.buttons["track-actions-ui-track-a"].waitForExistence(timeout: 5))
        openLibrary("Playlists"); XCTAssertTrue(app.staticTexts["Persistent Road"].waitForExistence(timeout: 5))
        screenshot("Restored-Library")
    }
}
