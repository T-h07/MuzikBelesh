import XCTest

/// Phase 11.2 Profile preview and "Your Listening" dashboard on an isolated fixture library.
/// `--listening-fixture` seeds deterministic sessions through the real analytics repository:
/// 3h 37m in the last 7 days, 5h 12m in the last 30 and 8h 32m in total.
final class ListeningAnalyticsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
        app = XCUIApplication()
        app.launchEnvironment["MB_UI_TEST_ID"] = UUID().uuidString
    }

    override func tearDownWithError() throws {
        attachFailureEvidence(app)
        app?.terminate()
    }

    private func launch(_ arguments: [String]) {
        app.launchArguments = ["--ui-testing", "--reset-ui-library"] + arguments
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier] }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openDashboard() -> XCUIElement {
        let avatar = app.buttons["home-profile-button"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 10))
        avatar.tap()
        let preview = app.buttons["profile-listening-activity"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        return preview
    }

    func testEmptyHistoryShowsInvitationInProfileAndDashboard() {
        launch([])
        let preview = openDashboard()
        waitUntil(preview, "label CONTAINS %@", "Your listening story starts here.", timeout: 5)
        XCTAssertFalse(app.staticTexts["Listening statistics"].exists, "The Phase 11.1 placeholder row is gone")
        capture("profile-listening-empty")
        preview.tap()
        XCTAssertTrue(element("listening-empty-title").waitForExistence(timeout: 5))
        XCTAssertTrue(element("listening-tracking-note").exists)
        let songs = element("listening-library-songs")
        XCTAssertTrue(songs.waitForExistence(timeout: 5))
        XCTAssertTrue(songs.label.contains("3"), "The library overview counts the fixture songs: \(songs.label)")
        capture("listening-dashboard-empty")
    }

    func testDashboardShowsRealTotalsAcrossRanges() {
        launch(["--listening-fixture"])
        let preview = openDashboard()
        waitUntil(preview, "label CONTAINS %@", "5 hours, 12 minutes", timeout: 5, message: "Profile preview shows the last 30 days")
        XCTAssertTrue(preview.label.contains("Fixture A"), "Most played song in the preview: \(preview.label)")
        capture("profile-listening-preview")
        preview.tap()

        let hero = element("listening-hero")
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        waitUntil(hero, "value CONTAINS %@", "3 hours, 37 minutes", timeout: 5)
        XCTAssertTrue(element("listening-activity-chart").exists)
        XCTAssertTrue(element("listening-chart-callout").exists)
        capture("listening-dashboard-7-days")

        app.buttons["listening-range-last30"].tap()
        waitUntil(hero, "value CONTAINS %@", "5 hours, 12 minutes", timeout: 5)
        app.buttons["listening-range-allTime"].tap()
        waitUntil(hero, "value CONTAINS %@", "8 hours, 32 minutes", timeout: 5)
        capture("listening-dashboard-all-time")
        app.buttons["listening-range-last7"].tap()
        waitUntil(hero, "value CONTAINS %@", "3 hours, 37 minutes", timeout: 5)

        let topSong = app.buttons["listening-top-song-1"]
        app.swipeUp()
        capture("listening-dashboard-highlights")
        XCTAssertTrue(topSong.waitForExistence(timeout: 5))
        XCTAssertTrue(topSong.label.contains("Fixture A"), topSong.label)
        app.swipeUp()
        capture("listening-dashboard-rankings")
        XCTAssertTrue(app.buttons["listening-top-artist-1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["listening-top-artist-1"].label.contains("Fixture Artist"))
        app.swipeUp()
        capture("listening-dashboard-collections")
        XCTAssertTrue(app.buttons["listening-top-playlist-1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["listening-top-playlist-1"].label.contains("Fixture Mix"))
    }

    func testTopSongPlaysAndTopPlaylistOpens() {
        launch(["--listening-fixture"])
        openDashboard().tap()
        let topSong = app.buttons["listening-top-song-1"]
        app.swipeUp()
        XCTAssertTrue(topSong.waitForExistence(timeout: 5))
        topSong.tap()

        app.swipeUp(); app.swipeUp()
        let playlist = app.buttons["listening-top-playlist-1"]
        XCTAssertTrue(playlist.waitForExistence(timeout: 5))
        playlist.tap()
        XCTAssertTrue(app.staticTexts["Fixture Mix"].waitForExistence(timeout: 5), "The playlist opens through existing navigation")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["profile-done"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 10), "Tapping the top song started playback")
    }

    func testLargeTextKeepsHeroAndRangesUsable() {
        launch(["--listening-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        openDashboard().tap()
        XCTAssertTrue(element("listening-hero").waitForExistence(timeout: 5))
        let range = app.buttons["listening-range-last30"]
        XCTAssertTrue(range.isHittable)
        XCTAssertGreaterThanOrEqual(range.frame.height, 44)
        capture("listening-dashboard-large-text")
        range.tap()
        waitUntil(element("listening-hero"), "value CONTAINS %@", "5 hours, 12 minutes", timeout: 5)
    }
}
