import XCTest

final class PlaylistFileImportUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        attachFailureEvidence(app)
        app?.terminate()
    }
    /// The Files picker's dismiss control. It is presented asynchronously by a remote
    /// view service, and iOS 26 sheets label it "Cancel" or "Close"; accept either, but
    /// only once it is actually on screen (never this screen's own Close button).
    private func pickerDismissButton(timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for label in ["Cancel", "Close"] {
                let button = app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label))
                    .allElementsBoundByIndex.first { $0.exists && $0.isHittable && $0.identifier != "playlist-import-close" }
                if let button { return button }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return nil
    }
    /// The model's selection, as published in the Confirm Import section.
    private func assertSelected(_ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let summary = app.staticTexts["playlist-import-selection-summary"]
        scrollTo(summary, file: file, line: line)
        waitUntil(summary, "label BEGINSWITH %@", "\(count) selected •", timeout: 3, file: file, line: line)
    }
    private func launch(fixture: Bool, extra: [String] = []) {
        app = XCUIApplication()
        app.launchEnvironment["MB_UI_TEST_ID"] = UUID().uuidString
        app.launchArguments = ["--ui-testing", "--reset-ui-library"] + (fixture ? ["--playlist-import-fixture"] : []) + extra
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10)); app.tabBars.buttons["Library"].tap()
        let filter = app.buttons["library-filter-Playlists"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5)); filter.tap()
        let entry = app.buttons["import-spotify-playlist"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
    }
    func testFilesPickerPresentsAndCancelsWithoutImport() throws {
        launch(fixture: false)
        let choose = app.buttons["playlist-import-choose-file"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); choose.tap()
        let cancel = try XCTUnwrap(pickerDismissButton(timeout: 15), "Files picker was not presented")
        cancel.tap()
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        waitUntil(choose, "hittable == true", timeout: 5, message: "Picker dismissed back to the import screen")
        XCTAssertFalse(app.staticTexts["playlist-import-success"].exists)
    }
    func testReviewCommitAndFiveHundredPlaceholders() {
        launch(fixture: true)
        let counts = app.staticTexts["playlist-import-counts"]
        XCTAssertTrue(counts.waitForExistence(timeout: 10)); XCTAssertEqual(counts.label, "1 valid • 0 invalid playlists")
        let confirm = app.buttons["playlist-import-confirm"]
        scrollTo(confirm); confirm.tap()
        let open = app.buttons["playlist-import-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        let count = app.staticTexts["migration-playlist-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5)); XCTAssertEqual(count.label, "500 songs")
        XCTAssertFalse(app.buttons["collection-play"].isEnabled)
    }

    // Phase 12: this flow was one test of ~40 accessibility checks plus a commit, which ran past
    // its 60 s allowance without hanging (v1.1.0 baseline failure). It is split in two; every
    // assertion is kept.
    func testMultipleSelectionDeselectSelectAllAndSwitchFlips() {
        launch(fixture: true, extra: ["--playlist-import-multiple"])
        let counts = app.staticTexts["playlist-import-counts"]
        XCTAssertTrue(counts.waitForExistence(timeout: 10))
        XCTAssertEqual(counts.label, "2 valid • 1 invalid playlists")
        let deselect = app.buttons["playlist-import-deselect-all"]
        scrollTo(deselect); deselect.tap()
        let confirm = app.buttons["playlist-import-confirm"]
        scrollTo(confirm); XCTAssertFalse(confirm.isEnabled)
        assertSelected(0)
        let selectAll = app.buttons["playlist-import-select-all"]
        scrollTo(selectAll, down: true); selectAll.tap()
        let anySwitch = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "playlist-import-select-")).firstMatch
        scrollTo(anySwitch)
        // Pin one candidate. A `firstMatch` query re-resolves after scrolling, and once the first
        // row leaves the lazy list it names the next candidate's switch instead (CI evidence:
        // the second flip tapped a different identifier, turning an already-selected one off).
        let firstSwitch = app.switches[anySwitch.identifier]
        XCTAssertEqual(firstSwitch.value as? String, "1")
        // Flip the switch itself and confirm the selection model changed, not only the control.
        flipSwitch(firstSwitch); XCTAssertEqual(firstSwitch.value as? String, "0")
        assertSelected(1)
        scrollTo(firstSwitch, down: true)
        flipSwitch(firstSwitch); XCTAssertEqual(firstSwitch.value as? String, "1")
        assertSelected(2)
    }

    func testMultipleSelectionRenamePreviewAndInvalidCandidate() {
        launch(fixture: true, extra: ["--playlist-import-multiple"])
        let counts = app.staticTexts["playlist-import-counts"]
        XCTAssertTrue(counts.waitForExistence(timeout: 10))
        XCTAssertEqual(counts.label, "2 valid • 1 invalid playlists")
        let selectAll = app.buttons["playlist-import-select-all"]
        scrollTo(selectAll, down: true); selectAll.tap()
        assertSelected(2)
        let confirm = app.buttons["playlist-import-confirm"]
        let name = app.textFields["playlist-import-destination-name"].firstMatch
        scrollTo(name); name.tap()
        let old = name.value as? String ?? ""
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + "Reviewed destination\n")
        let preview = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "playlist-import-preview-")).firstMatch
        scrollTo(preview); preview.tap()
        XCTAssertTrue(app.staticTexts["First song"].waitForExistence(timeout: 5))
        preview.tap()
        scrollTo(confirm); XCTAssertTrue(confirm.isEnabled)
        XCTAssertTrue(app.staticTexts["Validation failed — not importable"].exists)
        confirm.tap()
        let open = app.buttons["playlist-import-open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        XCTAssertTrue(app.staticTexts["playlist-detail-name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["playlist-detail-name"].label, "Reviewed destination")
    }

    func testThousandEntryScrollDashboardInspectionAndRestartSmoke() {
        // Commit of 1,000 entries plus a relaunch: allowance raised for this test only (cap 120 s).
        executionTimeAllowance = 120
        launch(fixture: true, extra: ["--playlist-import-thousand"])
        XCTAssertTrue(app.staticTexts["playlist-import-counts"].waitForExistence(timeout: 10))
        let confirm = app.buttons["playlist-import-confirm"]
        scrollTo(confirm); confirm.tap()
        let open = app.buttons["playlist-import-open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 15)); open.tap()
        XCTAssertTrue(app.staticTexts["migration-playlist-count"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["migration-playlist-count"].label, "1,000 songs")
        // Diagnostics are no longer on the playlist screen; they open on request.
        XCTAssertFalse(app.buttons["migration-dashboard-toggle"].exists, "The playlist screen shows no migration diagnostics")
        openMigrationDetails()
        let toggle = app.buttons["migration-dashboard-toggle"]
        scrollTo(toggle); toggle.tap()
        let pending = app.descendants(matching: .any)["migration-breakdown-pending"].firstMatch
        scrollTo(pending); XCTAssertTrue(pending.exists)
        app.buttons["migration-details-done"].tap()
        XCTAssertTrue(app.staticTexts["migration-playlist-count"].waitForExistence(timeout: 5))
        let start = Date()
        for _ in 0..<12 { app.swipeUp(velocity: .fast) }
        // Read the rows from one consistent snapshot. Querying element-by-element while a
        // fast fling is still decelerating races cell reuse ("No matches found" in CI #298).
        let visibleIDs = settledVisibleOccurrenceIDs()
        XCTAssertFalse(visibleIDs.isEmpty, "Rows must remain usable after rapid scrolling")
        XCTAssertFalse(app.staticTexts["Synthetic song 0"].isHittable)
        XCTAssertEqual(Set(visibleIDs).count, visibleIDs.count)
        guard let inspectedID = visibleIDs.first else { return }
        let inspected = app.buttons[inspectedID]
        let visible = visibleIDs
        inspected.tap()
        XCTAssertTrue(app.staticTexts["migration-inspector-status"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["migration-inspector-status"].label, "Awaiting local audio")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "migration-occurrence-play-")).firstMatch.exists)
        let evidence = XCTAttachment(string: "1,000-entry dataset; twelve rapid scrolls and entry inspection elapsed: \(Date().timeIntervalSince(start)) seconds; visible occurrence IDs: \(visible). No latency threshold claimed.")
        evidence.lifetime = .keepAlways; add(evidence)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.tabBars.buttons["Library"].tap()
        app.buttons["library-filter-Playlists"].tap()
        let playlist = app.staticTexts["Synthetic Import"]
        XCTAssertTrue(playlist.waitForExistence(timeout: 10)); playlist.tap()
        XCTAssertTrue(app.staticTexts["migration-playlist-count"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["migration-playlist-count"].label, "1,000 songs")
        // Import metadata lives in Migration Details (playlist ••• menu).
        openMigrationDetails()
        let details = app.buttons["migration-dashboard-toggle"]
        scrollTo(details); details.tap()
        scrollTo(app.staticTexts["migration-unresolved-count"])
        XCTAssertEqual(app.staticTexts["migration-unresolved-count"].label, "Unresolved: 1,000") // Locale-grouped, like "1,000 songs".
    }

    private func openMigrationDetails(file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["playlist-actions"].tap()
        let item = app.buttons["Migration Details"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), file: file, line: line); item.tap()
        XCTAssertTrue(app.navigationBars["Migration Details"].waitForExistence(timeout: 5), file: file, line: line)
    }

    /// Occurrence row identifiers fully on screen, from a single accessibility snapshot taken
    /// once two consecutive snapshots agree (the list has stopped moving). Bounded: 10 tries.
    private func settledVisibleOccurrenceIDs() -> [String] {
        func capture() -> [String] {
            guard let root = try? app.snapshot() else { return [] }
            let window = app.windows.firstMatch.frame
            var ids: [String] = []
            var stack: [XCUIElementSnapshot] = [root]
            while let node = stack.popLast() {
                if node.elementType == .button, node.identifier.hasPrefix("migration-occurrence-"),
                   !node.identifier.hasPrefix("migration-occurrence-play-"),
                   node.frame.minY >= window.minY + 120, node.frame.maxY <= window.maxY - 100 {
                    ids.append(node.identifier)
                }
                stack.append(contentsOf: node.children.reversed())
            }
            return ids
        }
        var previous = capture()
        for _ in 0..<10 {
            let next = capture()
            if !next.isEmpty && next == previous { return next }
            previous = next
        }
        return previous
    }

    /// Bounded: stops at the first swipe that makes `element` tappable.
    private func scrollTo(_ element: XCUIElement, down: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(scroll(app, toReveal: element, down ? .up : .down, maxSwipes: 15),
                      "\(element.identifier) never became tappable", file: file, line: line)
    }
}
