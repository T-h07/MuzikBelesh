import XCTest

/// Phase 11.3 Appearance screen. Each launch uses an isolated preferences suite keyed by
/// `MB_UI_TEST_ID`, so the real appearance setting is never read or changed.
///
/// The system `ColorPicker` sheet is owned by UIKit and is not automated here; its existence and
/// the custom swatch are checked, and colour conversion/persistence is covered by unit tests.
final class AppearanceSettingsUITests: XCTestCase {
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

    private func launch(reset: Bool = true, _ arguments: [String] = []) {
        app.launchArguments = ["--ui-testing"] + (reset ? ["--reset-ui-library"] : []) + arguments
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier] }
    private func preset(_ id: String) -> XCUIElement { app.buttons["appearance-preset-\(id)"] }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openProfile() {
        let avatar = app.buttons["home-profile-button"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 10))
        avatar.tap()
    }

    private func openAppearanceFromProfile() {
        openProfile()
        let row = app.buttons["profile-appearance"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(element("appearance-preview").waitForExistence(timeout: 5))
    }

    private func assertSelected(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = preset(id)
        XCTAssertTrue(button.waitForExistence(timeout: 5), file: file, line: line)
        waitUntil(button, "value == %@", "Selected", timeout: 5, message: "\(id) is announced as selected", file: file, line: line)
    }

    func testOpensFromProfileWithAllPresetsAndLimeSelected() {
        launch()
        openProfile()
        let row = app.buttons["profile-appearance"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(element("appearance-preview").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Make Muzik Belesh yours."].exists)
        for id in ["lime", "purple", "violet", "blue", "cyan", "pink", "red", "orange"] {
            XCTAssertTrue(preset(id).exists, "Preset \(id) is shown")
        }
        assertSelected("lime")
        XCTAssertEqual(preset("lime").label, "Original Lime")
        XCTAssertEqual(preset("purple").value as? String ?? "", "", "Only one preset is selected")
        XCTAssertFalse(app.buttons["appearance-reset"].isEnabled, "Nothing to restore on the original theme")
        capture("appearance-default-lime")
    }

    func testSelectingPresetsUpdatesSelectionAndResetRestoresLime() {
        launch()
        openAppearanceFromProfile()
        preset("purple").tap()
        assertSelected("purple")
        XCTAssertEqual(preset("lime").value as? String ?? "", "")
        capture("appearance-purple")
        for id in ["blue", "pink", "orange", "cyan"] { preset(id).tap() }
        assertSelected("cyan")
        capture("appearance-cyan")

        let reset = app.buttons["appearance-reset"]
        reveal(reset, in: app.scrollViews.firstMatch)
        XCTAssertTrue(reset.isEnabled)
        reset.tap()
        app.scrollViews.firstMatch.swipeDown()
        assertSelected("lime")
        XCTAssertFalse(reset.isEnabled)
    }

    func testCustomColourSectionAndCustomSelection() {
        launch()
        openAppearanceFromProfile()
        let swatch = app.buttons["appearance-custom-swatch"]
        reveal(swatch, in: app.scrollViews.firstMatch)
        XCTAssertTrue(element("appearance-custom-hex").exists)
        XCTAssertEqual(element("appearance-custom-hex").label, "#D6EEA3", "The custom colour starts as Original Lime")
        XCTAssertTrue(element("appearance-custom-picker").exists, "The native colour picker is offered")
        swatch.tap()
        waitUntil(swatch, "value == %@", "Selected", timeout: 5)
        app.scrollViews.firstMatch.swipeDown()
        XCTAssertEqual(preset("lime").value as? String ?? "", "", "A custom selection is distinct from the Lime preset")
        capture("appearance-custom")
    }

    func testSelectionSurvivesRelaunch() {
        launch()
        openAppearanceFromProfile()
        preset("violet").tap()
        assertSelected("violet")
        app.terminate()

        launch(reset: false)
        openAppearanceFromProfile()
        assertSelected("violet")
        XCTAssertEqual(preset("lime").value as? String ?? "", "")
        capture("appearance-after-relaunch")
    }

    func testOpensFromSettingsAndSharesTheSameTheme() {
        launch(["--theme-preset", "red"])
        openProfile()
        let settings = app.buttons["profile-open-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let row = app.buttons["settings-appearance"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(element("appearance-preview").waitForExistence(timeout: 5))
        assertSelected("red")
        preset("blue").tap()
        assertSelected("blue")
        capture("appearance-from-settings")
    }

    func testThemeChangeKeepsTabAndNavigation() {
        launch()
        let home = app.tabBars.buttons["Home"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        openAppearanceFromProfile()
        preset("pink").tap()
        assertSelected("pink")
        // Still on the Appearance screen: the change did not pop navigation or rebuild the sheet.
        XCTAssertTrue(element("appearance-preview").exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let done = app.buttons["profile-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Back on Profile")
        done.tap()
        XCTAssertTrue(app.buttons["home-profile-button"].waitForExistence(timeout: 5))
        XCTAssertTrue(home.isSelected, "The selected tab is preserved")
        XCTAssertEqual(app.tabBars.buttons.count, 4)
        capture("home-with-pink-theme")
    }
}
