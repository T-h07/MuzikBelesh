import XCTest

/// Real interaction tests for the review queue (fixture: `--review-queue-fixture`).
/// Songs 1–3 have five saved candidates each, best first; song 4 has none.
///
/// Each test is independent (fresh isolated library) and small enough for the 60 s
/// default allowance. Exact persisted candidate UUIDs, double submission and
/// background matching are covered at model level in MatchingReviewQueueTests.
final class ReviewQueueUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["MB_UI_TEST_ID"] = UUID().uuidString
        app.launchArguments = Self.arguments + ["--reset-ui-library"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10))
    }
    override func tearDownWithError() throws {
        attachFailureEvidence(app)
        app.terminate()
    }
    /// YouTube fixtures keep manual-link lookup and matching offline and deterministic.
    private static let arguments = ["--ui-testing", "--youtube-fixtures", "--review-queue-fixture"]

    // MARK: Scoped elements

    /// Mirrors AppBootstrap.reviewFixtureCandidateID (song and candidate are 0-based).
    private func candidateID(song: Int, candidate: Int) -> String {
        String(format: "00000000-0000-0000-0000-%012d", song * 10 + candidate)
    }
    private func useButton(song: Int, candidate: Int) -> XCUIElement {
        app.buttons.matching(identifier: "review-use-" + candidateID(song: song, candidate: candidate)).firstMatch
    }
    private var header: XCUIElement { app.otherElements["review-song-header"] }
    /// The review queue's own scroll view (the one containing the song header).
    private var queueScroll: XCUIElement { app.scrollViews.containing(.other, identifier: "review-song-header").firstMatch }

    // MARK: Steps

    private func openQueue(expecting title: String = "Review 1 of 4") {
        app.tabBars.buttons["Library"].tap()
        let filter = app.buttons["library-filter-Playlists"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5)); filter.tap()
        let playlist = app.staticTexts["Review queue"]
        XCTAssertTrue(playlist.waitForExistence(timeout: 5)); playlist.tap()
        // Migration review lives in Migration Details (playlist ••• menu).
        let actions = app.buttons["playlist-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5)); actions.tap()
        let details = app.buttons["Migration Details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5)); details.tap()
        let review = app.buttons["migration-review-songs"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertTrue(scroll(app, toReveal: review, maxSwipes: 6), "Review Songs is reachable")
        review.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
    }
    private func reveal(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        reveal(element, in: queueScroll, file: file, line: line)
    }
    /// Taps the exact candidate's Use button and confirms the dialog that names it.
    private func use(song: Int, candidate: Int) {
        let button = useButton(song: song, candidate: candidate)
        reveal(button)
        // A button revealed at the very bottom edge sits in the system gesture zone, where a
        // synthesized tap is swallowed (Phase 12 CI evidence: tap at y≈896 of 956, no dialog).
        // Swipe the scroll view that holds this button: after `reveal` has scrolled, the song
        // header (which `queueScroll` is keyed on) may already have left the hierarchy.
        if button.frame.maxY > app.frame.maxY - 80 {
            app.scrollViews.containing(.button, identifier: button.identifier).firstMatch.swipeUp(velocity: .slow)
        }
        button.tap()
        // The candidate's title also appears in the queue itself, so wait for the dialog's
        // own title before checking that its message names the tapped candidate.
        XCTAssertTrue(app.staticTexts["Use this recording?"].firstMatch.waitForExistence(timeout: 5), "Tapping Use opens the confirmation")
        let named = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Candidate \(candidate + 1) for song \(song + 1)")).firstMatch
        XCTAssertTrue(named.exists, "The dialog names the tapped candidate")
        // iOS 26 exposes a confirmationDialog action more than once under one identifier.
        let confirm = app.buttons.matching(identifier: "review-confirm-use").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3)); confirm.tap()
    }
    /// The queue shows exactly one song, it is the expected one, and it starts at the top.
    /// `position` is the queue position in the title; `song` the fixture song (1-based).
    private func assertShowing(_ position: Int, of total: Int, song: Int? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let number = song ?? position
        XCTAssertTrue(app.navigationBars["Review \(position) of \(total)"].waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(header.waitForExistence(timeout: 3), file: file, line: line)
        let titles = header.staticTexts.matching(identifier: "review-song-title")
        XCTAssertEqual(titles.count, 1, "One song is shown at a time", file: file, line: line)
        waitUntil(titles.firstMatch, "label == %@", "Review song \(number)", timeout: 3, file: file, line: line)
        XCTAssertTrue(header.isHittable, "A newly opened song starts at the top", file: file, line: line)
    }
    private func assertNoConfirmation(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(app.buttons.matching(identifier: "review-confirm-use").firstMatch.exists, message, file: file, line: line)
    }

    // MARK: Tests

    func testAllFiveCandidatesAreReachableIndividually() {
        openQueue()
        for index in 0..<5 {
            let button = useButton(song: 0, candidate: index)
            reveal(button)
            XCTAssertEqual(app.buttons.matching(identifier: button.identifier).count, 1, "Candidate \(index + 1) has exactly one control")
            XCTAssertTrue(button.isEnabled)
        }
        assertNoConfirmation("Scrolling to a candidate never opens a confirmation")
    }

    func testMiddleCandidateConfirmsAdvancesAndPersistsAcrossRelaunch() {
        // Two launches plus navigation: allowance raised for this test only (workflow cap 120 s).
        executionTimeAllowance = 120
        openQueue()
        use(song: 0, candidate: 2)
        assertShowing(2, of: 4) // Automatic advance to the next Spotify song, at the top.
        XCTAssertFalse(app.staticTexts["review-error"].exists)

        app.terminate()
        app.launchArguments = Self.arguments // Same isolated library, no reset.
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10))
        openQueue(expecting: "Review 1 of 3")
        // The confirmed song left the queue; the next song is first and still has all candidates.
        assertShowing(1, of: 3, song: 2)
        XCTAssertTrue(useButton(song: 1, candidate: 0).waitForExistence(timeout: 3))
        XCTAssertFalse(useButton(song: 0, candidate: 2).exists, "Song 1's decision persisted")
    }

    func testLastAndFirstCandidatesConfirmAndAdvance() {
        openQueue()
        use(song: 0, candidate: 4) // last (requires scrolling)
        assertShowing(2, of: 4)
        use(song: 1, candidate: 0) // first
        assertShowing(3, of: 4)
        XCTAssertFalse(app.staticTexts["review-error"].exists)
    }

    func testManualLinkConfirmationStaysInAppAndDismissesKeyboard() {
        openQueue()
        for _ in 0..<3 { app.buttons["review-next"].tap() } // Navigation only; selects nothing.
        assertShowing(4, of: 4)
        let field = app.textFields["migration-manual-link"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); reveal(field); field.tap()
        field.typeText("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        let lookup = app.buttons["migration-manual-lookup"]
        reveal(lookup); lookup.tap()
        let confirm = app.buttons["migration-manual-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10)); reveal(confirm); confirm.tap()
        let use = app.buttons["migration-manual-dialog-confirm"].firstMatch // The dialog exposes its button more than once.
        XCTAssertTrue(use.waitForExistence(timeout: 3)); use.tap()
        // Saved: the queue wraps to the first unresolved song, inside Muzik Belesh.
        assertShowing(1, of: 4)
        XCTAssertEqual(app.state, .runningForeground, "Use This Video never leaves the app")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "The keyboard is dismissed after confirming")
        XCTAssertFalse(app.staticTexts["review-error"].exists)
    }

    // Phase 12: one test of ~40 checks ran past its 60 s allowance without hanging (v1.1.0
    // baseline timeout). Buttons and swipes are now separate tests; every check is kept.
    func testNavigationResetsScrollAndNeverSelects() {
        openQueue()
        // Scroll to song 1's last candidate; scrolling alone never opens a confirmation.
        reveal(useButton(song: 0, candidate: 4))
        assertNoConfirmation("Scrolling never confirms")
        app.buttons["review-next"].tap()
        assertShowing(2, of: 4) // Also asserts the new song starts at the top.
        app.buttons["review-skip"].tap()
        assertShowing(3, of: 4)
        app.buttons["review-previous"].tap()
        assertShowing(2, of: 4)
        app.buttons["review-previous"].tap()
        assertShowing(1, of: 4)
        // Nothing was selected or rejected: song 1 still offers its first and last candidates.
        XCTAssertTrue(useButton(song: 0, candidate: 0).waitForExistence(timeout: 3))
        reveal(useButton(song: 0, candidate: 4))
        assertNoConfirmation("Navigation never confirms")
    }

    func testHeaderSwipesNavigateAndNeverSelect() {
        openQueue()
        header.swipeLeft() // Horizontal swipe on the song header navigates only.
        assertShowing(2, of: 4)
        header.swipeLeft()
        assertShowing(3, of: 4)
        assertNoConfirmation("Swiping never confirms")
        header.swipeRight()
        assertShowing(2, of: 4)
        header.swipeRight()
        assertShowing(1, of: 4)
        XCTAssertTrue(useButton(song: 0, candidate: 0).waitForExistence(timeout: 3), "Swiping selected or rejected nothing")
    }
}
