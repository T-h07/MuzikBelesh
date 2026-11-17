import Foundation
import SwiftUI

/// What is persisted. Version 1: `{"version":1,"selection":"lime","custom":"#D6EEA3"}`.
struct StoredTheme: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = StoredTheme.currentVersion
    var selection: String
    var custom: String
}

/// Device-local appearance storage. Injected so tests and UI tests never touch the real
/// preferences.
protocol ThemePreferenceStoring: AnyObject {
    func load() -> Data?
    func save(_ data: Data) throws
}

/// `UserDefaults` storage under one versioned key. Theme preferences are independent of the
/// database: no library, profile, playlist, download or analytics record is involved.
final class UserDefaultsThemePreferences: ThemePreferenceStoring {
    static let key = "appearance.theme.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> Data? { defaults.data(forKey: Self.key) }
    func save(_ data: Data) throws { defaults.set(data, forKey: Self.key) }
}

/// The single source of truth for the accent theme, owned by `AppContainer`.
///
/// The palette is published and placed into the SwiftUI environment at the root, so a change
/// re-renders only views that read accent colours. Nothing is reloaded: no library, player,
/// download, database or analytics work happens on a theme change.
@MainActor
final class ThemeService: ObservableObject {
    @Published private(set) var selection: ThemeSelection
    /// The saved custom colour, kept even while a preset is selected.
    @Published private(set) var customColor: ThemeRGB
    @Published private(set) var palette: ThemePalette
    /// Set when the last save failed; the applied theme is unchanged.
    @Published private(set) var lastError: String?

    static let defaultCustomColor = ThemePreset.lime.rgb
    /// Coalesces writes while the custom colour is being dragged.
    static let customSaveDelay: Duration = .milliseconds(400)

    private let store: ThemePreferenceStoring?
    private var pendingSave: Task<Void, Never>?

    init(store: ThemePreferenceStoring?) {
        self.store = store
        let restored = Self.restore(store?.load())
        selection = restored.selection
        customColor = restored.custom
        palette = ThemePalette(chosen: Self.color(for: restored.selection, custom: restored.custom))
    }

    /// Decodes stored data, falling back field by field: an unknown preset or a malformed
    /// custom colour never prevents launch and never touches any other data.
    static func restore(_ data: Data?) -> (selection: ThemeSelection, custom: ThemeRGB) {
        guard let data, let stored = try? JSONDecoder().decode(StoredTheme.self, from: data), stored.version == StoredTheme.currentVersion
        else { return (.default, defaultCustomColor) }
        let custom = ThemeRGB(hex: stored.custom)
        var selection = ThemeSelection(identifier: stored.selection) ?? .default
        if selection == .custom && custom == nil { selection = .default }
        return (selection, custom ?? defaultCustomColor)
    }

    static func color(for selection: ThemeSelection, custom: ThemeRGB) -> ThemeRGB {
        switch selection { case .preset(let preset): return preset.rgb; case .custom: return custom }
    }

    var effectiveColor: ThemeRGB { palette.chosen }

    func select(_ preset: ThemePreset) { apply(.preset(preset), custom: customColor); save() }

    /// Switches to the saved custom colour.
    func selectCustom() { apply(.custom, custom: customColor); save() }

    /// Live update while the system colour picker is dragged. The interface follows
    /// immediately; the write is coalesced and `commitCustomColor()` flushes it.
    func updateCustomColor(_ color: ThemeRGB) {
        guard color != customColor || selection != .custom else { return }
        apply(.custom, custom: color)
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.customSaveDelay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Persists any pending custom colour now (picker closed, screen left, app backgrounded).
    func commitCustomColor() {
        guard pendingSave != nil else { return }
        save()
    }

    /// Restores Original Lime. The saved custom colour is kept for later.
    func reset() { apply(.default, custom: customColor); save() }

    private func apply(_ selection: ThemeSelection, custom: ThemeRGB) {
        if self.selection != selection { self.selection = selection }
        if customColor != custom { customColor = custom }
        let next = ThemePalette(chosen: Self.color(for: selection, custom: custom))
        if palette != next { palette = next }
    }

    private func save() {
        pendingSave?.cancel(); pendingSave = nil
        guard let store else { return }
        do {
            let data = try JSONEncoder().encode(StoredTheme(selection: selection.identifier, custom: customColor.hex))
            try store.save(data)
            lastError = nil
        } catch {
            lastError = "Your appearance choice couldn't be saved. It applies until Muzik Belesh closes."
        }
    }
}

/// Places the theme into the environment and the root tint. Observes only `ThemeService`, so
/// a theme change never rebuilds containers, navigation or presentations.
struct ThemeRoot<Content: View>: View {
    @ObservedObject var theme: ThemeService
    let content: Content
    var body: some View {
        content
            .environment(\.themePalette, theme.palette)
            .environmentObject(theme)
            .tint(theme.palette.controlTint)
    }
}
