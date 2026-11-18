import XCTest

/// Phase 11.1 launch gate, onboarding and Profile editing on an isolated fixture library.
final class LocalProfileUITests: XCTestCase {
    private var app: XCUIApplication!
    private var identifier = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        identifier = UUID().uuidString
        app = XCUIApplication()
        app.launchEnvironment["MB_UI_TEST_ID"] = identifier
    }

    override func tearDownWithError() throws {
        attachFailureEvidence(app)
        app?.terminate()
    }

    private func launch(_ arguments: [String]) {
        app.launchArguments = ["--ui-testing"] + arguments
        app.launch()
    }

    private func relaunch() {
        app.terminate()
        launch([])
    }

    private var homeTab: XCUIElement { app.tabBars.buttons["Home"] }
    private var onboardingTitle: XCUIElement { app.staticTexts["onboarding-title"] }
    private var usernameField: XCUIElement { app.textFields["profile-username-field"] }

    private func openProfile() {
        let avatar = app.buttons["home-profile-button"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 10))
        avatar.tap()
        XCTAssertTrue(app.staticTexts["profile-username"].waitForExistence(timeout: 5))
    }

    private func replaceUsername(with text: String) {
        XCTAssertTrue(usernameField.waitForExistence(timeout: 5))
        // Tap the trailing edge so the cursor lands after the existing text.
        usernameField.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let current = usernameField.value as? String ?? ""
        usernameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2) + text)
    }

    func testNewUserCreatesProfileAndKeepsLibraryAcrossRelaunch() {
        // A reset library without a profile is both a new install and a v1.1.0 upgrade:
        // the fixture songs already exist when onboarding appears.
        launch(["--reset-ui-library", "--profile-onboarding"])
        XCTAssertTrue(onboardingTitle.waitForExistence(timeout: 10))
        XCTAssertFalse(homeTab.exists, "The tab interface must not appear before a profile exists")
        let create = app.buttons["onboarding-create-profile"]
        XCTAssertTrue(create.exists)
        XCTAssertFalse(create.isEnabled, "An empty username cannot be submitted")

        XCTAssertTrue(usernameField.waitForExistence(timeout: 5))
        usernameField.tap()
        usernameField.typeText("Ëndrit Belësh")
        XCTAssertTrue(create.isEnabled)
        usernameField.typeText("\n") // Done submits, the same action as Create Profile.

        XCTAssertTrue(homeTab.waitForExistence(timeout: 10))
        XCTAssertFalse(onboardingTitle.exists)
        let fixtureSong = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Fixture'")).firstMatch
        XCTAssertTrue(fixtureSong.waitForExistence(timeout: 5), "The existing library is still there after onboarding")

        openProfile()
        XCTAssertEqual(app.staticTexts["profile-username"].label, "Ëndrit Belësh")

        relaunch()
        XCTAssertTrue(homeTab.waitForExistence(timeout: 10))
        XCTAssertFalse(onboardingTitle.exists, "A stored profile skips onboarding")
        openProfile()
        XCTAssertEqual(app.staticTexts["profile-username"].label, "Ëndrit Belësh")
    }

    func testInvalidUsernameShowsFeedbackAndCannotBeSubmitted() {
        launch(["--reset-ui-library", "--profile-onboarding"])
        XCTAssertTrue(usernameField.waitForExistence(timeout: 10))
        usernameField.tap()
        usernameField.typeText("   ")
        XCTAssertTrue(app.staticTexts["profile-username-error"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["onboarding-create-profile"].isEnabled)
        usernameField.typeText(String(repeating: "x", count: 31))
        XCTAssertTrue(app.staticTexts["profile-username-error"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["onboarding-create-profile"].isEnabled)
        usernameField.typeText("\n")
        XCTAssertFalse(homeTab.exists, "Submitting an invalid name keeps onboarding open")
    }

    func testExistingUserSkipsOnboardingAndAvatarOpensProfile() {
        launch(["--reset-ui-library"])
        XCTAssertTrue(homeTab.waitForExistence(timeout: 10))
        XCTAssertFalse(onboardingTitle.exists)
        XCTAssertTrue(app.buttons["Settings"].exists, "Settings stays in the Home header")
        openProfile()
        XCTAssertEqual(app.staticTexts["profile-username"].label, "UI Listener")
        XCTAssertTrue(app.buttons["profile-edit"].exists)
        XCTAssertTrue(app.buttons["profile-open-settings"].exists)
        app.buttons["profile-done"].tap()
        XCTAssertTrue(app.buttons["home-profile-button"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.buttons.count, 4, "No fifth tab for Profile")
    }

    func testEditCancelPreservesAndSavePersistsAcrossRelaunch() {
        launch(["--reset-ui-library"])
        openProfile()

        app.buttons["profile-edit"].tap()
        replaceUsername(with: "Discarded Name")
        app.buttons["edit-profile-cancel"].tap()
        XCTAssertTrue(app.staticTexts["profile-username"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["profile-username"].label, "UI Listener", "Cancel discards the draft")

        app.buttons["profile-edit"].tap()
        replaceUsername(with: "Renamed Listener")
        let save = app.buttons["edit-profile-save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        waitUntil(app.staticTexts["profile-username"], "label == %@", "Renamed Listener", timeout: 5)
        XCTAssertFalse(app.buttons["edit-profile-save"].exists, "The editor closes after a committed save")

        relaunch()
        XCTAssertTrue(homeTab.waitForExistence(timeout: 10))
        openProfile()
        XCTAssertEqual(app.staticTexts["profile-username"].label, "Renamed Listener")
    }

    func testStorageReadFailureIsRecoverableWithoutOnboarding() {
        launch(["--reset-ui-library", "--profile-load-failure"])
        XCTAssertTrue(app.staticTexts["profile-error-message"].waitForExistence(timeout: 10))
        XCTAssertFalse(onboardingTitle.exists, "A read failure is never treated as a missing profile")
        XCTAssertFalse(homeTab.exists)
        app.buttons["profile-error-retry"].tap()
        XCTAssertTrue(homeTab.waitForExistence(timeout: 10))
        openProfile()
        XCTAssertEqual(app.staticTexts["profile-username"].label, "UI Listener", "The stored profile was preserved")
    }
}
