import XCTest

/// Phase 11.5 dynamic collection artwork. Fixture playlists come from `ArtworkFixtureSeeder`
/// (`--artwork-fixtures`): Five Covers (5 distinct covers), Two Covers, Empty Mix, Custom Cover
/// and 40 Bulk Mix playlists. Each launch uses an isolated library and preferences suite.
final class CollectionArtworkUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
        app = XCUIApplication()
        app.launchEnvironment["MB_UI_TEST_ID"] = UUID().uuidString
    }

    override func tearDownWithError() throws {
        attachFailureEvidence(app)
        app?.terminate()
    }

    private func launch(reset: Bool = true, _ arguments: [String] = []) {
        app.launchArguments = ["--ui-testing"] + (reset ? ["--reset-ui-library", "--artwork-fixtures"] : []) + arguments
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 15))
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func element(_ identifier: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: identifier).firstMatch }
    private func artwork(_ playlistID: String) -> XCUIElement { element("collection-artwork-playlist-\(playlistID)") }

    private func openPlaylists() {
        let tab = app.tabBars.buttons["Library"]
        if !tab.isSelected { tab.tap() }
        let chip = app.buttons["library-filter-Playlists"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        if !chip.isHittable { app.scrollViews["library-filters"].swipeLeft() }
        chip.tap()
    }

    private func openPlaylist(_ name: String) {
        openPlaylists()
        let row = app.staticTexts[name]
        XCTAssertTrue(row.waitForExistence(timeout: 8), "\(name) is listed")
        reveal(row, in: app)
        row.tap()
        XCTAssertTrue(element("playlist-detail-name").waitForExistence(timeout: 5))
    }

    private func openArtworkSettings() {
        let actions = element("playlist-actions")
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        let settings = app.buttons["playlist-artwork-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.buttons["collection-artwork-done"].waitForExistence(timeout: 5))
    }

    private func closeArtworkSettings() {
        app.buttons["collection-artwork-done"].tap()
        XCTAssertTrue(app.buttons["collection-artwork-done"].waitForNonExistence(timeout: 5))
    }

    private func assertArtwork(_ playlistID: String, label: String, value: String, file: StaticString = #filePath, line: UInt = #line) {
        let header = artwork(playlistID)
        XCTAssertTrue(header.waitForExistence(timeout: 8), "Artwork \(playlistID) exists", file: file, line: line)
        waitUntil(header, "label == %@", label, timeout: 8, message: "label of \(playlistID)", file: file, line: line)
        waitUntil(header, "value == %@", value, timeout: 8, message: "value of \(playlistID)", file: file, line: line)
    }

    func testPlaylistWithFiveCoversShowsAnAutomaticMosaic() {
        launch()
        openPlaylists()
        XCTAssertTrue(app.staticTexts["Five Covers"].waitForExistence(timeout: 8))
        capture("artwork-playlist-list")
        openPlaylist("Five Covers")
        assertArtwork("artwork-five", label: "Automatic artwork for Five Covers", value: "4 song covers")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "collection-artwork-playlist-artwork-five").count, 1, "One accessibility element for the whole mosaic")
        capture("artwork-five-covers-header")
    }

    func testFewerThanFourCoversAndEmptyPlaylistsFallBackSafely() {
        launch()
        openPlaylist("Two Covers")
        assertArtwork("artwork-two", label: "Automatic artwork for Two Covers", value: "2 song covers")
        capture("artwork-two-covers")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openPlaylist("Empty Mix")
        assertArtwork("artwork-empty", label: "Artwork for Empty Mix", value: "No song covers")
        capture("artwork-empty-placeholder")
    }

    func testCustomCoverTakesPriorityAndCanBeRemoved() {
        launch()
        openPlaylist("Custom Cover")
        assertArtwork("artwork-custom", label: "Custom artwork for Custom Cover", value: "Custom cover")
        openArtworkSettings()
        XCTAssertTrue(element("collection-artwork-custom-note").waitForExistence(timeout: 5),
                      "Your custom cover takes priority. Remove it to display the automatic mosaic.")
        XCTAssertTrue(element("collection-artwork-preview").exists, "The mosaic preview is shown even while the custom cover wins")
        capture("artwork-settings-custom")
        let remove = app.buttons["collection-artwork-remove-cover"]
        reveal(remove, in: app.collectionViews.firstMatch)
        remove.tap()
        let confirm = app.buttons["collection-artwork-confirm-remove"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 8), "The custom cover is gone")
        closeArtworkSettings()
        assertArtwork("artwork-custom", label: "Automatic artwork for Custom Cover", value: "3 song covers") // Songs 2 and 3 share a cover.
        capture("artwork-custom-removed-mosaic")
    }

    func testPerCollectionModeOverridesTheDefaultAndPersists() {
        launch()
        openPlaylist("Five Covers")
        openArtworkSettings()
        let staticMode = app.buttons["collection-artwork-mode-static"]
        XCTAssertTrue(staticMode.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["collection-artwork-mode-appDefault"].isSelected, "New collections use the app default")
        staticMode.tap()
        waitUntil(staticMode, "selected == true", timeout: 5)
        closeArtworkSettings()
        assertArtwork("artwork-five", label: "Artwork for Five Covers", value: "Song cover")
        capture("artwork-static-mode")

        app.terminate()
        launch(reset: false)
        openPlaylist("Five Covers")
        assertArtwork("artwork-five", label: "Artwork for Five Covers", value: "Song cover")
        openArtworkSettings()
        XCTAssertTrue(app.buttons["collection-artwork-mode-static"].isSelected, "The mode survives a relaunch")
        app.buttons["collection-artwork-mode-appDefault"].tap()
        closeArtworkSettings()
        assertArtwork("artwork-five", label: "Automatic artwork for Five Covers", value: "4 song covers")
    }

    func testGlobalSettingDisablesMosaicsAndPersists() {
        launch()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let appearance = app.buttons["settings-appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        let toggle = app.switches["appearance-automatic-artwork"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        reveal(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "1", "Automatic artwork is on by default")
        flipSwitch(toggle)
        XCTAssertEqual(toggle.value as? String, "0")
        capture("artwork-global-setting-off")

        app.terminate()
        launch(reset: false)
        openPlaylist("Five Covers")
        assertArtwork("artwork-five", label: "Artwork for Five Covers", value: "Song cover")
        openArtworkSettings()
        app.buttons["collection-artwork-mode-automatic"].tap()
        closeArtworkSettings()
        assertArtwork("artwork-five", label: "Automatic artwork for Five Covers", value: "4 song covers")
        capture("artwork-override-on-while-global-off")
    }

    func testMosaicsRenderWithANonDefaultTheme() {
        launch(reset: true, ["--theme-preset", "purple"])
        openPlaylist("Two Covers")
        assertArtwork("artwork-two", label: "Automatic artwork for Two Covers", value: "2 song covers")
        capture("artwork-theme-purple")
    }

    func testScrollingManyPlaylistMosaicsStaysResponsive() {
        launch()
        openPlaylists()
        XCTAssertTrue(app.staticTexts["Bulk Mix 01"].waitForExistence(timeout: 8))
        let last = app.staticTexts["Bulk Mix 40"]
        XCTAssertTrue(scroll(app, toReveal: last, .down, maxSwipes: 20, velocity: .fast), "Scrolling reaches the end of 40+ mosaic rows")
        capture("artwork-bulk-bottom")
        let first = app.staticTexts["Five Covers"]
        XCTAssertTrue(scroll(app, toReveal: first, .up, maxSwipes: 20, velocity: .fast), "Scrolling back up is not blocked by decoding")
        XCTAssertTrue(app.tabBars.buttons["Library"].isHittable, "The app stays responsive")
    }
}
