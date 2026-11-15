import XCTest

/// Real interaction tests for the review queue (fixture: `--review-queue-fixture`).
/// Songs 1–3 have five saved candidates each, best first; song 4 has none.
final class ReviewQueueUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["MB_UI_TEST_ID"] = UUID().uuidString
        // YouTube fixtures keep manual-link lookup and matching offline and deterministic.
        app.launchArguments = ["--ui-testing", "--reset-ui-library", "--youtube-fixtures", "--review-queue-fixture"]
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
    /// Mirrors AppBootstrap.reviewFixtureCandidateID (song and candidate are 0-based).
    private func candidateID(song: Int, candidate: Int) -> String {
        String(format: "00000000-0000-0000-0000-%012d", song * 10 + candidate)
    }
    private func openQueue() {
        app.tabBars.buttons["Library"].tap()
        let filter = app.buttons["library-filter-Playlists"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5)); filter.tap()
        let playlist = app.staticTexts["Review queue"]; XCTAssertTrue(playlist.waitForExistence(timeout: 5)); playlist.tap()
        let review = app.buttons["migration-review-songs"]
        for _ in 0..<6 where !review.isHittable { app.swipeUp() }
        XCTAssertTrue(review.waitForExistence(timeout: 5)); review.tap()
        XCTAssertTrue(app.navigationBars["Review 1 of 4"].waitForExistence(timeout: 5))
    }
    private func reveal(_ element: XCUIElement) {
        for _ in 0..<10 where !(element.exists && element.isHittable) { app.scrollViews.firstMatch.swipeUp(velocity: .slow) }
        XCTAssertTrue(element.isHittable, "\(element.identifier) must be tappable")
    }
    private func tapDialog(_ label: String) {
        let sheetButton = app.sheets.buttons[label]
        if sheetButton.waitForExistence(timeout: 3) { sheetButton.tap(); return }
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertFalse(matches.isEmpty, "Confirmation \(label) missing"); matches.last?.tap()
    }
    private func use(song: Int, candidate: Int) {
        let button = app.buttons["review-use-" + candidateID(song: song, candidate: candidate)]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        reveal(button); button.tap()
        // The dialog names the exact tapped candidate.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Candidate \(candidate + 1) for song \(song + 1)")).firstMatch
            .waitForExistence(timeout: 3))
        tapDialog("Use This Recording")
    }
    private func assertTopOfSong(_ number: Int, of total: Int) {
        XCTAssertTrue(app.navigationBars["Review \(number) of \(total)"].waitForExistence(timeout: 5))
        let title = app.staticTexts["review-song-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertEqual(title.label, "Review song \(number)")
        XCTAssertTrue(title.isHittable, "A newly opened song starts at the top")
    }

    func testFirstMiddleAndLastCandidatesSelectAndManualLinkDismissesKeyboard() {
        openQueue()
        XCTAssertTrue(app.buttons["review-use-" + candidateID(song: 0, candidate: 4)].exists, "All five candidates are available, not only three")
        use(song: 0, candidate: 2)          // middle
        assertTopOfSong(2, of: 4)
        use(song: 1, candidate: 4)          // last (requires scrolling)
        assertTopOfSong(3, of: 4)
        use(song: 2, candidate: 0)          // first
        assertTopOfSong(4, of: 4)

        // Manual link for a song without candidates.
        let field = app.textFields["migration-manual-link"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); reveal(field); field.tap()
        field.typeText("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        app.buttons["migration-manual-lookup"].tap()
        let confirm = app.buttons["migration-manual-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10)); reveal(confirm); confirm.tap()
        tapDialog("Use This Video")
        XCTAssertTrue(app.otherElements["review-caught-up"].waitForExistence(timeout: 5) || app.staticTexts["You're all caught up."].waitForExistence(timeout: 2))
        XCTAssertFalse(app.keyboards.firstMatch.exists, "The keyboard is dismissed after confirming")
        XCTAssertFalse(app.staticTexts["review-error"].exists)

        app.buttons["review-back-to-playlist"].tap()
        let summary = app.staticTexts["matching-summary"]
        for _ in 0..<6 where !summary.exists { app.swipeUp() }
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("4 matched"), summary.label)
    }

    func testNavigationResetsScrollAndSwipesOrScrollsNeverSelect() {
        openQueue()
        // Scroll deep into song 1's candidates; scrolling alone never opens a confirmation.
        for _ in 0..<3 { app.scrollViews.firstMatch.swipeUp(velocity: .slow) }
        XCTAssertFalse(app.sheets.firstMatch.exists)
        app.buttons["review-next"].tap()
        assertTopOfSong(2, of: 4)
        // Horizontal swipe on the song header navigates only.
        app.staticTexts["review-song-title"].swipeLeft()
        assertTopOfSong(3, of: 4)
        XCTAssertFalse(app.sheets.firstMatch.exists, "Swiping never confirms")
        app.buttons["review-previous"].tap()
        assertTopOfSong(2, of: 4)
        app.buttons["review-skip"].tap()
        assertTopOfSong(3, of: 4)
        // Nothing was selected by navigation: song 1 still offers its first candidate.
        app.buttons["review-previous"].tap(); app.buttons["review-previous"].tap()
        assertTopOfSong(1, of: 4)
        XCTAssertTrue(app.buttons["review-use-" + candidateID(song: 0, candidate: 0)].waitForExistence(timeout: 3))
    }
}
