import XCTest

final class PlaylistFileImportUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        if let app, (testRun?.failureCount ?? 0) > 0 {
            let evidence = XCTAttachment(screenshot: app.screenshot()); evidence.lifetime = .keepAlways; add(evidence)
            let tree = XCTAttachment(string: app.debugDescription); tree.lifetime = .keepAlways; add(tree)
        }
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
    /// A List-row Toggle's accessibility frame (and, on iOS 26, its nested switch's frame)
    /// spans the whole row, so tapping the element's centre hits the label and does not
    /// flip the switch (CI run 43735713704). The switch is trailing-aligned: tap 30 pt in
    /// from the row's trailing edge, inside the control, and wait for the value to change.
    private func toggle(_ row: XCUIElement) {
        let before = row.value as? String ?? ""
        let width = max(row.frame.width, 1)
        row.coordinate(withNormalizedOffset: CGVector(dx: max(0.5, (width - 30) / width), dy: 0.5)).tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", before), object: row)
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 3), .completed, "Toggle \(row.identifier) did not change from \(before)")
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
        let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: choose)
        XCTAssertEqual(XCTWaiter().wait(for: [back], timeout: 5), .completed, "Picker dismissed back to the import screen")
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
        XCTAssertTrue(count.waitForExistence(timeout: 5)); XCTAssertEqual(count.label, "500 imported • 0 manually added • 500 total • 0 available offline")
        XCTAssertFalse(app.buttons["collection-play"].isEnabled)
    }

    func testMultipleSelectionRenamePreviewAndInvalidCandidate() {
        launch(fixture: true, extra: ["--playlist-import-multiple"])
        let counts = app.staticTexts["playlist-import-counts"]
        XCTAssertTrue(counts.waitForExistence(timeout: 10))
        XCTAssertEqual(counts.label, "2 valid • 1 invalid playlists")
        let deselect = app.buttons["playlist-import-deselect-all"]
        scrollTo(deselect); deselect.tap()
        let confirm = app.buttons["playlist-import-confirm"]
        scrollTo(confirm); XCTAssertFalse(confirm.isEnabled)
        let selectAll = app.buttons["playlist-import-select-all"]
        scrollTo(selectAll, down: true); selectAll.tap()
        let firstSwitch = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "playlist-import-select-")).firstMatch
        scrollTo(firstSwitch); XCTAssertEqual(firstSwitch.value as? String, "1")
        toggle(firstSwitch); XCTAssertEqual(firstSwitch.value as? String, "0")
        toggle(firstSwitch); XCTAssertEqual(firstSwitch.value as? String, "1")
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
        launch(fixture: true, extra: ["--playlist-import-thousand"])
        XCTAssertTrue(app.staticTexts["playlist-import-counts"].waitForExistence(timeout: 10))
        let confirm = app.buttons["playlist-import-confirm"]
        scrollTo(confirm); confirm.tap()
        let open = app.buttons["playlist-import-open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 15)); open.tap()
        XCTAssertTrue(app.staticTexts["migration-playlist-count"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["migration-playlist-count"].label, "1,000 imported • 0 manually added • 1,000 total • 0 available offline")
        let toggle = app.buttons["migration-dashboard-toggle"]
        scrollTo(toggle); toggle.tap()
        let pending = app.descendants(matching: .any)["migration-breakdown-pending"].firstMatch
        scrollTo(pending); XCTAssertTrue(pending.exists)
        scrollTo(toggle, down: true); toggle.tap()
        let start = Date()
        for _ in 0..<12 { app.swipeUp(velocity: .fast) }
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "migration-occurrence-"))
        let visible = rows.allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertFalse(visible.isEmpty, "Rows must remain usable after rapid scrolling")
        XCTAssertFalse(app.staticTexts["Synthetic song 0"].isHittable)
        XCTAssertEqual(Set(visible.map(\.identifier)).count, visible.count)
        guard let inspected = visible.first else { return }
        inspected.tap()
        XCTAssertTrue(app.staticTexts["migration-inspector-status"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["migration-inspector-status"].label, "Awaiting local audio")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "migration-occurrence-play-")).firstMatch.exists)
        let evidence = XCTAttachment(string: "1,000-entry dataset; twelve rapid scrolls and entry inspection elapsed: \(Date().timeIntervalSince(start)) seconds; visible occurrence IDs: \(visible.map(\.identifier)). No latency threshold claimed.")
        evidence.lifetime = .keepAlways; add(evidence)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.tabBars.buttons["Library"].tap()
        app.buttons["library-filter-Playlists"].tap()
        let playlist = app.staticTexts["Synthetic Import"]
        XCTAssertTrue(playlist.waitForExistence(timeout: 10)); playlist.tap()
        XCTAssertTrue(app.staticTexts["migration-playlist-count"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["migration-playlist-count"].label, "1,000 imported • 0 manually added • 1,000 total • 0 available offline")
        // Import metadata now lives in Migration Details; matching is the primary progress.
        let details = app.buttons["migration-dashboard-toggle"]
        scrollTo(details); details.tap()
        scrollTo(app.staticTexts["migration-unresolved-count"])
        XCTAssertEqual(app.staticTexts["migration-unresolved-count"].label, "Unresolved: 1000")
    }

    private func scrollTo(_ element: XCUIElement, down: Bool = false) {
        for _ in 0..<15 where !element.isHittable {
            if down { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(element.isHittable)
    }
}
