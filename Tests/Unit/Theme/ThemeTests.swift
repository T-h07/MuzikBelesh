import Combine
import SwiftUI
import XCTest
@testable import OFFLINE

/// In-memory preferences with optional write failure.
final class MemoryThemePreferences: ThemePreferenceStoring {
    var data: Data?
    var failWrites = false
    var writes = 0
    init(_ data: Data? = nil) { self.data = data }
    func load() -> Data? { data }
    func save(_ data: Data) throws {
        if failWrites { throw CocoaError(.fileWriteUnknown) }
        writes += 1
        self.data = data
    }
    func stored() -> StoredTheme? { data.flatMap { try? JSONDecoder().decode(StoredTheme.self, from: $0) } }
    static func with(selection: String, custom: String, version: Int = StoredTheme.currentVersion) -> MemoryThemePreferences {
        MemoryThemePreferences(try! JSONEncoder().encode(StoredTheme(version: version, selection: selection, custom: custom)))
    }
}

final class ThemePresetTests: XCTestCase {
    func testDefaultIsOriginalLime() {
        XCTAssertEqual(ThemeSelection.default, .preset(.lime))
        XCTAssertEqual(ThemePreset.lime.rgb.hex, "#D6EEA3")
        XCTAssertEqual(ThemePalette.default.accentRGB.hex, "#D6EEA3", "The upgrade default looks exactly like Phase 11.2")
    }

    func testEightNamedPresetsResolveToDistinctColours() {
        XCTAssertEqual(ThemePreset.allCases.count, 8)
        XCTAssertEqual(Set(ThemePreset.allCases.map(\.rgb)).count, 8)
        XCTAssertEqual(Set(ThemePreset.allCases.map(\.name)).count, 8)
        XCTAssertEqual(ThemePreset.allCases.map(\.name), ["Original Lime", "Purple", "Violet", "Blue", "Cyan", "Pink", "Red", "Orange"])
        for preset in ThemePreset.allCases {
            XCTAssertEqual(ThemeSelection(identifier: preset.rawValue), .preset(preset))
            XCTAssertGreaterThanOrEqual(preset.rgb.contrast(with: .black), ThemePalette.minimumContrast, "\(preset.name) is readable on black")
            XCTAssertFalse(ThemePalette(chosen: preset.rgb).isAdjustedForContrast, "\(preset.name) is shown exactly as defined")
        }
    }

    func testCustomIsADistinctSelection() {
        XCTAssertEqual(ThemeSelection(identifier: "custom"), .custom)
        XCTAssertNotEqual(ThemeSelection.custom, .preset(.lime))
        XCTAssertNil(ThemeSelection(identifier: "neon"))
        XCTAssertNil(ThemeSelection(identifier: ""))
    }
}

final class ThemeColorTests: XCTestCase {
    func testHexRoundTripIsCanonical() {
        let color = ThemeRGB(red: 0x12, green: 0xAB, blue: 0xEF)
        XCTAssertEqual(color.hex, "#12ABEF")
        XCTAssertEqual(ThemeRGB(hex: color.hex), color)
        XCTAssertEqual(ThemeRGB(hex: "12abef"), color)
        for value in 0...255 where value % 17 == 0 {
            let rgb = ThemeRGB(red: UInt8(value), green: UInt8(255 - value), blue: UInt8(value / 2))
            XCTAssertEqual(ThemeRGB(hex: rgb.hex), rgb)
        }
    }

    func testMalformedHexIsRejected() {
        for bad in ["", "#", "#12345", "#1234567", "#GG0000", "zzzzzz", "#12 345", "rgb(1,2,3)", "#+12345", "١٢٣٤٥٦", "#12345\u{0}"] {
            XCTAssertNil(ThemeRGB(hex: bad), bad)
        }
    }

    func testColorConversionDropsTransparencyAndClampsToSRGB() throws {
        let translucent = Color(.sRGB, red: 1, green: 0.5, blue: 0, opacity: 0.2)
        XCTAssertEqual(try XCTUnwrap(ThemeRGB(color: translucent)).hex, "#FF8000")
        let wide = Color(.displayP3, red: 1, green: 0, blue: 0, opacity: 1)
        let converted = try XCTUnwrap(ThemeRGB(color: wide))
        XCTAssertEqual(converted.red, 255, "P3 red outside sRGB is clamped, not wrapped")
        XCTAssertEqual(ThemeRGB(color: ThemeRGB(hex: "#3366CC")!.color), ThemeRGB(hex: "#3366CC"))
    }

    func testContrastForegroundForLightAndDarkAccents() {
        XCTAssertEqual(ThemePalette(chosen: ThemePreset.lime.rgb).onAccentRGB, .black)
        XCTAssertEqual(ThemePalette(chosen: ThemeRGB(hex: "#FFFFFF")!).onAccentRGB, .black)
        let navy = ThemePalette(chosen: ThemeRGB(hex: "#101020")!)
        XCTAssertEqual(navy.chosen.hex, "#101020", "The saved colour is never changed")
        XCTAssertTrue(navy.isAdjustedForContrast)
        XCTAssertGreaterThanOrEqual(navy.accentRGB.contrast(with: .black), ThemePalette.minimumContrast)
        XCTAssertGreaterThanOrEqual(navy.onAccentRGB.contrast(with: navy.accentRGB), ThemePalette.minimumContrast)
        let blue = ThemePalette(chosen: ThemeRGB(hex: "#1D4ED8")!)
        XCTAssertGreaterThanOrEqual(blue.accentRGB.contrast(with: .black), ThemePalette.minimumContrast)
        XCTAssertGreaterThanOrEqual(blue.onAccentRGB.contrast(with: blue.accentRGB), 4.5)
        XCTAssertGreaterThan(ThemeRGB.white.contrast(with: .black), 20)
    }

    func testPaletteIsDeterministic() {
        for hex in ["#101020", "#7F00FF", "#00FF00", "#808080", "#D6EEA3"] {
            let rgb = ThemeRGB(hex: hex)!
            XCTAssertEqual(ThemePalette(chosen: rgb), ThemePalette(chosen: rgb))
        }
    }
}

@MainActor final class ThemeServiceTests: XCTestCase {
    func testMissingPreferencesUseOriginalLime() {
        let service = ThemeService(store: MemoryThemePreferences())
        XCTAssertEqual(service.selection, .preset(.lime))
        XCTAssertEqual(service.palette, .default)
        XCTAssertEqual(ThemeService(store: nil).palette, .default)
    }

    func testCorruptOrUnsupportedPreferencesFallBackSafely() {
        XCTAssertEqual(ThemeService(store: MemoryThemePreferences(Data("not json".utf8))).selection, .default)
        XCTAssertEqual(ThemeService(store: MemoryThemePreferences.with(selection: "neon", custom: "#123456")).selection, .default)
        XCTAssertEqual(ThemeService(store: MemoryThemePreferences.with(selection: "neon", custom: "#123456")).customColor.hex, "#123456", "A valid custom colour survives a bad selection")
        let badCustom = ThemeService(store: MemoryThemePreferences.with(selection: "custom", custom: "#12345Z"))
        XCTAssertEqual(badCustom.selection, .default)
        XCTAssertEqual(badCustom.customColor, ThemeService.defaultCustomColor)
        XCTAssertEqual(ThemeService(store: MemoryThemePreferences.with(selection: "purple", custom: "#123456", version: 99)).selection, .default, "Unknown versions are not guessed at")
    }

    func testSelectedPresetAndCustomColourPersist() {
        let store = MemoryThemePreferences()
        let service = ThemeService(store: store)
        service.select(.purple)
        XCTAssertEqual(store.stored()?.selection, "purple")
        XCTAssertEqual(ThemeService(store: store).selection, .preset(.purple))

        service.updateCustomColor(ThemeRGB(hex: "#336699")!)
        XCTAssertEqual(service.selection, .custom)
        XCTAssertEqual(service.palette.chosen.hex, "#336699", "The picker applies immediately")
        service.commitCustomColor()
        XCTAssertEqual(store.stored(), StoredTheme(selection: "custom", custom: "#336699"))
        let relaunched = ThemeService(store: store)
        XCTAssertEqual(relaunched.selection, .custom)
        XCTAssertEqual(relaunched.customColor.hex, "#336699")
    }

    func testDraggingCoalescesWritesAndCommitFlushes() {
        let store = MemoryThemePreferences()
        let service = ThemeService(store: store)
        for value in stride(from: 0, through: 250, by: 10) { service.updateCustomColor(ThemeRGB(red: UInt8(value), green: 40, blue: 200)) }
        XCTAssertEqual(store.writes, 0, "No write per drag step")
        XCTAssertEqual(service.palette.chosen, ThemeRGB(red: 250, green: 40, blue: 200))
        service.commitCustomColor()
        XCTAssertEqual(store.writes, 1)
        XCTAssertEqual(store.stored()?.custom, "#FA28C8")
        service.commitCustomColor()
        XCTAssertEqual(store.writes, 1, "Nothing pending, nothing written")
    }

    func testCoalescedWriteHappensWithoutCommit() async throws {
        let store = MemoryThemePreferences()
        let service = ThemeService(store: store)
        service.updateCustomColor(ThemeRGB(hex: "#445566")!)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(store.stored()?.custom, "#445566")
    }

    func testResetRestoresLimeAndKeepsCustomColour() {
        let store = MemoryThemePreferences()
        let service = ThemeService(store: store)
        service.updateCustomColor(ThemeRGB(hex: "#AA3355")!)
        service.reset()
        XCTAssertEqual(service.selection, .preset(.lime))
        XCTAssertEqual(service.palette, .default)
        XCTAssertEqual(service.customColor.hex, "#AA3355")
        XCTAssertEqual(store.stored(), StoredTheme(selection: "lime", custom: "#AA3355"))
        service.selectCustom()
        XCTAssertEqual(service.palette.chosen.hex, "#AA3355", "Custom can be reselected after reset")
    }

    func testChangesNotifyObserversAndRapidSelectionsSettle() {
        let service = ThemeService(store: MemoryThemePreferences())
        var notifications = 0
        let cancellable = service.objectWillChange.sink { notifications += 1 }
        for preset in ThemePreset.allCases + ThemePreset.allCases.reversed() { service.select(preset) }
        withExtendedLifetime(cancellable) {}
        XCTAssertGreaterThan(notifications, 0)
        XCTAssertEqual(service.selection, .preset(.lime))
        notifications = 0
        let again = service.objectWillChange.sink { notifications += 1 }
        service.select(.lime)
        withExtendedLifetime(again) {}
        XCTAssertEqual(notifications, 0, "Selecting the current theme publishes nothing")
    }

    func testWriteFailureKeepsTheAppliedThemeAndReports() {
        let store = MemoryThemePreferences()
        store.failWrites = true
        let service = ThemeService(store: store)
        service.select(.red)
        XCTAssertEqual(service.selection, .preset(.red))
        XCTAssertNotNil(service.lastError)
        store.failWrites = false
        service.select(.blue)
        XCTAssertNil(service.lastError)
        XCTAssertEqual(store.stored()?.selection, "blue")
    }

    func testThemeStorageTouchesNoOtherPreferenceOrData() throws {
        let suite = "ThemeIsolation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("keep", forKey: "unrelated.preference")
        let service = ThemeService(store: UserDefaultsThemePreferences(defaults: defaults))
        service.select(.orange)
        service.reset()
        XCTAssertEqual(defaults.string(forKey: "unrelated.preference"), "keep")
        let keys = Set(defaults.dictionaryRepresentation().keys).intersection(["unrelated.preference", UserDefaultsThemePreferences.key])
        XCTAssertEqual(keys, ["unrelated.preference", UserDefaultsThemePreferences.key])
    }

    func testThemeChangesDoNotTouchProfileLibraryOrPlayback() async throws {
        let fixture = try LibraryFixture(count: 2)
        retainUntilTeardown(fixture)
        let profile = LocalProfileRepository(db: fixture.storage.database.dbQueue, paths: fixture.paths)
        _ = try profile.create(username: "Theme Tester", avatar: nil)
        let before = try librarySnapshot(fixture.storage.database.dbQueue)
        let (player, transport, _) = fixture.services()
        try await player.play(trackID: fixture.ids[0], contextTrackIDs: fixture.ids, contextKind: "library")
        let replacements = transport.replacements
        let generation = player.activeItemGeneration
        let service = ThemeService(store: MemoryThemePreferences())
        for preset in ThemePreset.allCases { service.select(preset) }
        service.updateCustomColor(ThemeRGB(hex: "#123456")!)
        service.commitCustomColor()
        service.reset()
        XCTAssertEqual(transport.replacements, replacements, "No AVPlayer item replacement")
        XCTAssertEqual(player.activeItemGeneration, generation)
        XCTAssertEqual(player.state.currentTrackID, fixture.ids[0])
        XCTAssertEqual(try profile.load()?.username, "Theme Tester")
        XCTAssertEqual(try librarySnapshot(fixture.storage.database.dbQueue), before)
    }

    func testSavedThemeIsAvailableSynchronouslyAtConstruction() {
        // AppContainer builds ThemeService first, synchronously: the first frame already has the
        // saved theme, so there is no lime flash on launch.
        let store = MemoryThemePreferences.with(selection: "cyan", custom: "#123456")
        let service = ThemeService(store: store)
        XCTAssertEqual(service.selection, .preset(.cyan))
        XCTAssertEqual(service.palette.chosen, ThemePreset.cyan.rgb)
        XCTAssertEqual(service.customColor.hex, "#123456")
        XCTAssertEqual(store.writes, 0, "Restoring never rewrites the saved value")
    }
}
