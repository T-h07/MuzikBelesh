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
        let tab = app.tabBars.buttons["Library"]
        if !tab.isSelected { tab.tap() }
        let chip = app.buttons["library-filter-" + filter.replacingOccurrences(of: " ", with: "-")]
        let filters = app.scrollViews["library-filters"]
        XCTAssertTrue(chip.exists || chip.waitForExistence(timeout: 5))
        // XCTest can raise an error while computing isHittable for a chip beyond
        // a horizontal scroll view. Reveal the whole frame before tapping it.
        let viewport = filters.frame.intersection(app.frame)
        func visible() -> Bool { let frame = chip.frame; return !frame.isEmpty && viewport.contains(frame) }
        for _ in 0..<4 {
            let frame = chip.frame
            if !frame.isEmpty && viewport.contains(frame) { break }
            if frame.minX < viewport.minX { filters.swipeRight() } else { filters.swipeLeft() }
        }
        XCTAssertTrue(visible(), "The selected library category must be fully visible"); chip.tap()
    }
    private func change(_ field: XCUIElement, to text: String) {
        XCTAssertTrue(field.exists || field.waitForExistence(timeout: 5))
        if field.identifier.hasPrefix("album-") { revealAlbumField(field) }
        field.tap()
        let existing = field.value as? String ?? ""
        if !existing.isEmpty && existing != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(text)
    }
    private func revealAlbumField(_ field: XCUIElement) {
        let bar = app.navigationBars["Edit Album"].exists ? app.navigationBars["Edit Album"] : app.navigationBars["Create Album"]
        let top = bar.frame.maxY
        let appFrame = app.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<5 {
            let frame = field.frame
            let keyboard = app.keyboards.firstMatch
            // Keyboard AX bounds omit the predictive-input strip. Leave one
            // field-height of clearance and drag only within visible form content.
            let bottom = keyboard.exists ? keyboard.frame.minY - frame.height : appFrame.maxY
            if frame.minY >= top && frame.maxY <= bottom && field.isHittable { return }
            let height = bottom - top
            XCTAssertGreaterThan(height, 44)
            let upper = origin.withOffset(CGVector(dx: appFrame.midX, dy: top + height * 0.2))
            let lower = origin.withOffset(CGVector(dx: appFrame.midX, dy: top + height * 0.75))
            if frame.minY < top { upper.press(forDuration: 0.05, thenDragTo: lower) }
            else { lower.press(forDuration: 0.05, thenDragTo: upper) }
        }
        XCTFail("The album field must be visible above the keyboard before editing")
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
    // SwiftUI confirmationDialog can expose nested Button nodes under one
    // accessibility identifier on newer iOS runtimes. Choose the innermost
    // visible actionable node instead of an ambiguous app.buttons[id] lookup.
    private func tapDeletionConfirmation(_ identifier: String) {
        let matches = app.descendants(matching: .any).matching(identifier: identifier)
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 5))
        let action = matches.allElementsBoundByIndex.reversed().first {
            ($0.elementType == .button || $0.elementType == .popUpButton) && $0.isHittable
        }
        guard let action else { XCTFail("No visible deletion action for \(identifier)"); return }
        action.tap()
    }

    // On iOS 26 the confirmation is presented as a popover with no accessible
    // Cancel button. Dismissing the popover is the user's non-destructive path.
    // Check that the dialog actually closes before asserting song preservation.
    private func cancelTrackDeletion() {
        let confirm = app.descendants(matching: .any).matching(identifier: "confirm-delete-track").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        let cancels = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Cancel")).allElementsBoundByIndex
        if let cancel = cancels.reversed().first(where: {
            ($0.elementType == .button || $0.elementType == .popUpButton) && $0.isHittable
        }) {
            cancel.tap()
        } else {
            XCTAssertTrue(app.popovers.firstMatch.exists, "No Cancel action or dismissible confirmation popover")
            // Status-bar corner is outside the popover; never tap its delete row.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.03)).tap()
        }
        absent(confirm)
    }

    // List content below the large album header is lazily materialized on SE.
    // Reveal the real empty-state row instead of weakening its assertion.
    private func assertEmptyAlbumMessageVisible() {
        let message = app.staticTexts["This album is empty. Add songs from your Library."]
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), "Album detail must contain a scrollable list")
        for _ in 0..<5 {
            if message.exists && message.isHittable { break }
            list.swipeUp()
        }
        XCTAssertTrue(message.exists && message.isHittable, "The empty album message must be visible after revealing its list section")
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

    private func createAlbum(_ name: String) {
        openLibrary("Albums"); app.buttons["create-album"].tap()
        change(app.textFields["album-name"], to: name)
        app.buttons["album-save"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 8))
    }

    func testEmptyAlbumCreationAndSearchPersistAfterRelaunch() {
        createAlbum("Empty Album")
        app.staticTexts["Empty Album"].firstMatch.tap()
        assertEmptyAlbumMessageVisible()
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.tabBars.buttons["Search"].tap()
        change(app.textFields["search-field"], to: "empty album")
        tapVisible(app.staticTexts["Empty Album"].firstMatch)
        absent(app.keyboards.firstMatch)
        assertEmptyAlbumMessageVisible()
        screenshot("Empty-Album-Restored")
    }

    func testAlbumNameAndArtistSurviveRelaunch() {
        openLibrary("Albums")
        app.staticTexts["Fixture Album"].firstMatch.tap()
        app.buttons["album-actions"].tap(); app.buttons["Edit Album"].tap()
        change(app.textFields["album-name"], to: "Café Night")
        change(app.textFields["album-artist"], to: "Night Artist")
        screenshot("Album-Editor")
        app.buttons["album-save"].tap()
        XCTAssertTrue(app.staticTexts["Café Night"].waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.tabBars.buttons["Search"].tap()
        change(app.textFields["search-field"], to: "cafe night\n")
        tapVisible(app.staticTexts["Café Night"].firstMatch)
        absent(app.keyboards.firstMatch)
        XCTAssertTrue(app.staticTexts["Night Artist"].exists)
        screenshot("Renamed-Album-Restored")
    }

    func testAlbumYearAndDescriptionSurviveRelaunch() {
        openLibrary("Albums")
        app.staticTexts["Fixture Album"].firstMatch.tap()
        app.buttons["album-actions"].tap(); app.buttons["Edit Album"].tap()
        change(app.textFields["album-year"], to: "2026")
        change(app.textFields["album-description"], to: "Evening collection")
        screenshot("Album-Year-Description-Editor")
        app.buttons["album-save"].tap()
        XCTAssertTrue(app.staticTexts["2026"].waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.tabBars.buttons["Search"].tap()
        // Description uniquely matches the album, keeping it visible while the
        // keyboard is open. Name/artist search above also matches its song rows.
        change(app.textFields["search-field"], to: "Evening collection")
        tapVisible(app.staticTexts["Fixture Album"].firstMatch)
        absent(app.keyboards.firstMatch)
        XCTAssertTrue(app.staticTexts["2026"].exists)
        XCTAssertTrue(app.staticTexts["Evening collection"].exists)
        screenshot("Album-Year-Description-Restored")
    }

    func testCreateAlbumWithSongsMovesPrimaryMembershipAndCanReorder() {
        openLibrary("Albums"); app.buttons["create-album"].tap()
        change(app.textFields["album-name"], to: "Organized")
        app.buttons["album-choose-songs"].tap()
        for id in ["ui-track-a", "ui-track-b", "ui-track-c"] { tapVisible(app.buttons["select-track-" + id]) }
        app.buttons["album-confirm-add"].tap(); app.buttons["album-save"].tap()
        XCTAssertTrue(app.staticTexts["Organized"].waitForExistence(timeout: 8))
        app.staticTexts["Organized"].firstMatch.tap()
        app.buttons["album-reorder"].tap()
        tapVisible(app.buttons["album-move-up-ui-track-a"])
        let a = app.buttons["album-move-up-ui-track-a"], b = app.buttons["album-move-up-ui-track-b"]
        expectation(for: NSPredicate { _, _ in a.exists && b.exists && a.frame.minY < b.frame.minY }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        screenshot("Album-Reordering")
        app.buttons["album-reorder"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.staticTexts["Fixture Album"].exists, "Moved songs must not remain in their original primary album")
    }

    func testAlbumAddRemovePlayShuffleAndDeletePreserveMusicAndPlayer() {
        createAlbum("Playback Album")
        app.staticTexts["Playback Album"].firstMatch.tap()
        app.buttons["album-add-songs"].tap()
        tapVisible(app.buttons["select-track-ui-track-a"]); tapVisible(app.buttons["select-track-ui-track-b"])
        app.buttons["album-confirm-add"].tap()
        tapVisible(app.buttons["collection-play"])
        XCTAssertTrue(app.buttons["Open Now Playing"].waitForExistence(timeout: 5))
        tapVisible(app.buttons["collection-shuffle"])
        actions("ui-track-b"); app.buttons["Remove from Album"].tap()
        absent(app.buttons["track-actions-ui-track-b"])
        app.buttons["album-actions"].tap(); app.buttons["Delete Album"].tap()
        tapDeletionConfirmation("confirm-delete-album")
        XCTAssertTrue(app.buttons["Open Now Playing"].waitForExistence(timeout: 5))
        openLibrary("Songs")
        for id in ["ui-track-a", "ui-track-b", "ui-track-c"] { XCTAssertTrue(app.buttons["track-actions-" + id].exists) }
        screenshot("Album-Deleted-Music-Preserved")
    }

    private func dragVisibleResultsAbovePlayer() {
        let results = app.scrollViews["local-search-results"]
        let frame = results.frame
        // Scroll-view AX bounds extend behind its safe-area accessories. The
        // default swipe starts on the player there, so use the measured visible
        // results region, not fixed screen coordinates or the covered footer.
        let bottom = min(frame.maxY, app.buttons["sleep-timer-indicator"].frame.minY)
        let height = bottom - frame.minY
        XCTAssertGreaterThan(height, 44)
        let origin = results.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
        origin.withOffset(CGVector(dx: 0, dy: height * 0.8)).press(forDuration: 0.05,
            thenDragTo: origin.withOffset(CGVector(dx: 0, dy: height * 0.2)))
    }

    func testSearchSubmitDismissesKeyboardAndCanReopen() {
        app.tabBars.buttons["Search"].tap()
        let field = app.textFields["search-field"]
        field.tap(); field.typeText("Fixture\n")
        absent(app.keyboards.firstMatch)
        field.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(abs(app.buttons["keyboard-done"].frame.midY - field.frame.midY), 8, "Done belongs beside the field, not in an oversized keyboard accessory")
        screenshot("Search-Keyboard-Open-No-Accessory")
        app.buttons["keyboard-done"].tap(); absent(app.keyboards.firstMatch)
        let closedFrame = app.tabBars.firstMatch.frame
        var measurements = ["closed tab bar: \(closedFrame)"]
        for _ in 0..<2 {
            field.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            let tabs = app.tabBars.firstMatch
            XCTAssertTrue(tabs.buttons["Library"].isHittable)
            XCTAssertLessThanOrEqual(tabs.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
            measurements.append("open tab bar: \(tabs.frame), keyboard: \(app.keyboards.firstMatch.frame)")
            app.buttons["keyboard-done"].tap(); absent(app.keyboards.firstMatch)
            expectation(for: NSPredicate { _, _ in abs(tabs.frame.minY - closedFrame.minY) < 1 }, evaluatedWith: app)
            waitForExpectations(timeout: 5)
        }
        let geometry = XCTAttachment(string: measurements.joined(separator: "\n")); geometry.name = "Keyboard layout diagnostics"; geometry.lifetime = .keepAlways; add(geometry)
        screenshot("Search-Keyboard-Closed")
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 5))
    }

    func testNewPlaylistIsImmediatelySearchableFromSearchTab() {
        createPlaylist("Searchable Road")
        app.tabBars.buttons["Search"].tap(); app.buttons["Your Library"].tap()
        change(app.textFields["search-field"], to: "Searchable Road")
        XCTAssertTrue(app.staticTexts["Searchable Road"].waitForExistence(timeout: 8))
        app.staticTexts["Searchable Road"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Playlist"].waitForExistence(timeout: 5))
        absent(app.keyboards.firstMatch)
    }

    func testLibrarySearchRemainsAvailableWhenFilteringPlaylists() {
        createPlaylist("Library Search Road")
        let field = app.textFields["search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        change(field, to: "Library Search Road\n")
        XCTAssertTrue(app.staticTexts["Library Search Road"].waitForExistence(timeout: 5))
    }

    func testSearchTabTransitionClearScrollAndPlaybackKeepNavigationAccessible() {
        openLibrary(); app.staticTexts["Fixture A"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Open Now Playing"].waitForExistence(timeout: 5))
        app.buttons["Open Now Playing"].tap(); app.buttons["Sleep Timer"].tap()
        app.buttons["5 min"].tap(); app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["sleep-timer-indicator"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Search"].tap()
        let field = app.textFields["search-field"]
        field.tap(); field.typeText("Fixture")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Library"].isHittable)
        XCTAssertTrue(app.buttons["Open Now Playing"].isHittable)
        XCTAssertTrue(app.buttons["sleep-timer-indicator"].isHittable)
        XCTAssertFalse(app.keyboards.firstMatch.frame.intersects(app.buttons["Open Now Playing"].frame))
        XCTAssertFalse(app.keyboards.firstMatch.frame.intersects(app.buttons["sleep-timer-indicator"].frame))
        screenshot("Keyboard-With-Player-And-Timer")
        app.buttons["sleep-timer-indicator"].tap(); app.buttons["Done"].tap()
        absent(app.keyboards.firstMatch)
        field.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.tabBars.buttons["Library"].tap(); absent(app.keyboards.firstMatch)
        XCTAssertTrue(app.buttons["Open Now Playing"].isHittable)
        app.tabBars.buttons["Search"].tap(); field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        dragVisibleResultsAbovePlayer(); absent(app.keyboards.firstMatch)
        field.tap(); app.buttons["Clear search"].tap(); absent(app.keyboards.firstMatch)
        change(field, to: "Fixture\n")
        tapVisible(app.scrollViews["local-search-results"].staticTexts["Fixture B"].firstMatch)
        absent(app.keyboards.firstMatch)
        XCTAssertTrue(app.buttons["Open Now Playing"].isHittable)
        screenshot("Search-Keyboard-Navigation")
    }

    func testUniversalLibraryGroupsFiltersAndSearchAfterRelaunch() {
        createPlaylist("Fixture Road")
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.tabBars.buttons["Search"].tap()
        change(app.textFields["search-field"], to: "Fixture\n")
        for kind in ["songs", "albums", "artists", "playlists"] {
            let section = app.descendants(matching: .any).matching(identifier: "search-section-" + kind).firstMatch
            for _ in 0..<4 { if section.exists { break }; app.scrollViews["local-search-results"].swipeUp() }
            XCTAssertTrue(section.exists)
        }
        tapVisible(app.staticTexts["Fixture Road"].firstMatch)
        XCTAssertTrue(app.navigationBars["Playlist"].waitForExistence(timeout: 5)); absent(app.keyboards.firstMatch)
        app.tabBars.buttons["Library"].tap()
        openLibrary("Songs"); change(app.textFields["search-field"], to: "Fixture\n")
        openLibrary("Albums")
        XCTAssertEqual(app.textFields["search-field"].value as? String, "Fixture")
        XCTAssertFalse(app.buttons["track-actions-ui-track-a"].exists)
        XCTAssertTrue(app.staticTexts["Fixture Album"].waitForExistence(timeout: 5))
        openLibrary("Playlists")
        XCTAssertEqual(app.textFields["search-field"].value as? String, "Fixture")
        XCTAssertTrue(app.staticTexts["Fixture Road"].waitForExistence(timeout: 5))
        screenshot("Universal-Library-Search")
    }

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
        tapDeletionConfirmation("confirm-delete-playlist")
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
        openLibrary(); actions("ui-track-c"); app.buttons["Delete Song"].tap()
        cancelTrackDeletion()
        XCTAssertTrue(app.buttons["track-actions-ui-track-c"].exists)
        actions("ui-track-c"); app.buttons["Delete Song"].tap()
        tapDeletionConfirmation("confirm-delete-track")
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
