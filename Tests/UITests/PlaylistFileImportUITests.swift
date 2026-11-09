import XCTest

final class PlaylistFileImportUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { app?.terminate() }
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
    func testFilesPickerPresentsAndCancelsWithoutImport() {
        launch(fixture: false)
        let choose = app.buttons["playlist-import-choose-file"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); choose.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.tap()
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
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
        XCTAssertTrue(count.waitForExistence(timeout: 5)); XCTAssertEqual(count.label, "500 songs • 0 available offline")
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
        scrollTo(firstSwitch); XCTAssertEqual(firstSwitch.value as? String, "1"); firstSwitch.tap()
        XCTAssertEqual(firstSwitch.value as? String, "0"); firstSwitch.tap()
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
        XCTAssertEqual(app.staticTexts["migration-playlist-count"].label, "1000 songs • 0 available offline")
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
        XCTAssertEqual(app.staticTexts["migration-playlist-count"].label, "1000 songs • 0 available offline")
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
