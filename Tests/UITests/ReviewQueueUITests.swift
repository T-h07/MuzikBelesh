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
    /// The review queue's own scroll container.
    private var queueScroll: XCUIElement {
        let scoped = app.scrollViews.containing(.any, identifier: "review-song-header").firstMatch
        return scoped.exists ? scoped : app.scrollViews.firstMatch
    }
    private func visible(_ element: XCUIElement) -> Bool { element.exists && element.isHittable }
    /// Candidate rows render lazily: an off-screen row may not be in the accessibility tree
    /// yet (below) or any more (above). Scroll down, then back up, until it is tappable.
    private func reveal(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<10 where !visible(element) { queueScroll.swipeUp(velocity: .slow) }
        for _ in 0..<14 where !visible(element) { queueScroll.swipeDown(velocity: .slow) }
        XCTAssertTrue(visible(element), "\(element.identifier) must be tappable", file: file, line: line)
    }
    private func scrollToTop() {
        let header = app.otherElements["review-song-header"]
        for _ in 0..<14 where !visible(header) { queueScroll.swipeDown(velocity: .fast) }
        XCTAssertTrue(visible(header))
    }
    private func useButton(song: Int, candidate: Int) -> XCUIElement {
        app.buttons.matching(identifier: "review-use-" + candidateID(song: song, candidate: candidate)).firstMatch
    }
    /// Every saved candidate (five per fixture song) can be reached and has exactly one control.
    private func assertAllCandidatesReachable(song: Int) {
        for index in 0..<5 {
            let button = useButton(song: song, candidate: index)
            reveal(button)
            XCTAssertEqual(app.buttons.matching(identifier: button.identifier).count, 1, "Candidate \(index + 1) has one control")
        }
        XCTAssertEqual(app.buttons.matching(identifier: "review-use-" + candidateID(song: song, candidate: 5)).count, 0,
                       "Only the five saved candidates are offered")
        XCTAssertFalse(app.sheets.firstMatch.exists, "Scrolling never opens a confirmation")
        scrollToTop()
    }
    private func tapDialog(_ label: String) {
        let sheetButton = app.sheets.buttons[label]
        if sheetButton.waitForExistence(timeout: 3) { sheetButton.tap(); return }
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertFalse(matches.isEmpty, "Confirmation \(label) missing"); matches.last?.tap()
    }
    private func use(song: Int, candidate: Int) {
        let button = useButton(song: song, candidate: candidate)
        reveal(button); button.tap()
        // The dialog names the exact tapped candidate.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Candidate \(candidate + 1) for song \(song + 1)")).firstMatch
            .waitForExistence(timeout: 3))
        tapDialog("Use This Recording")
    }
    private func assertTopOfSong(_ number: Int, of total: Int) {
        XCTAssertTrue(app.navigationBars["Review \(number) of \(total)"].waitForExistence(timeout: 5))
        // Scoped to the queue header: exactly one song title is shown.
        let header = app.otherElements["review-song-header"]
        XCTAssertTrue(header.waitForExistence(timeout: 3))
        let titles = header.staticTexts.matching(identifier: "review-song-title")
        XCTAssertEqual(titles.count, 1, "One song is shown at a time")
        let title = titles.firstMatch
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Review song \(number)"), object: title)
        XCTAssertEqual(XCTWaiter().wait(for: [expected], timeout: 3), .completed, "Expected Review song \(number)")
        XCTAssertTrue(title.isHittable, "A newly opened song starts at the top")
    }

    func testFirstMiddleAndLastCandidatesSelectAndManualLinkDismissesKeyboard() {
        openQueue()
        assertAllCandidatesReachable(song: 0) // All five, not only three; rows render lazily.
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
        // Scroll down to song 1's last candidate; scrolling alone never opens a confirmation.
        reveal(useButton(song: 0, candidate: 4))
        XCTAssertFalse(app.sheets.firstMatch.exists)
        app.buttons["review-next"].tap()
        assertTopOfSong(2, of: 4)
        // Horizontal swipe on the song header navigates only.
        app.otherElements["review-song-header"].swipeLeft()
        assertTopOfSong(3, of: 4)
        XCTAssertFalse(app.sheets.firstMatch.exists, "Swiping never confirms")
        app.buttons["review-previous"].tap()
        assertTopOfSong(2, of: 4)
        app.buttons["review-skip"].tap()
        assertTopOfSong(3, of: 4)
        // Nothing was selected by navigation: song 1 still offers its first candidate.
        app.buttons["review-previous"].tap(); app.buttons["review-previous"].tap()
        assertTopOfSong(1, of: 4)
        XCTAssertTrue(useButton(song: 0, candidate: 0).waitForExistence(timeout: 3))
        assertAllCandidatesReachable(song: 0) // Still all five: navigation rejected nothing.
        app.buttons["review-next"].tap(); assertTopOfSong(2, of: 4)
        assertAllCandidatesReachable(song: 1)
    }
}
