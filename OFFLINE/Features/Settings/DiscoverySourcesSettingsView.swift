import SwiftUI

/// Spotify matching sources: optional private SearXNG instance and direct YouTube fallback.
struct DiscoverySourcesSettingsView: View {
    let settings: DiscoverySourceSettings
    let transport: any YouTubeTransport
    @State private var enabled = false
    @State private var baseURL = ""
    @State private var engines = ""
    @State private var allowLAN = false
    @State private var directYouTube = true
    @State private var status: String?
    @State private var statusIsError = false
    @State private var testing = false
    var body: some View {
        Section {
            Toggle("Use SearXNG", isOn: $enabled).onChange(of: enabled) { _, value in settings.searxEnabled = value }
                .accessibilityIdentifier("searxng-enabled")
            TextField("https://searxng.example.lan", text: $baseURL)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .onSubmit { save() }.accessibilityIdentifier("searxng-url")
            TextField("Video engines", text: $engines)
                .textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit { save() }
            Toggle("Allow HTTP on local network (development)", isOn: $allowLAN)
                .onChange(of: allowLAN) { _, value in settings.allowLANHTTP = value }
            Button(testing ? "Testing…" : "Save and Test Connection") { save(); test() }.disabled(testing)
                .accessibilityIdentifier("searxng-test")
            if let status { Text(status).font(.caption).foregroundStyle(statusIsError ? AppColors.error : AppColors.textSecondary) }
            Toggle("Direct YouTube search fallback", isOn: $directYouTube)
                .onChange(of: directYouTube) { _, value in settings.directYouTubeEnabled = value }
        } header: { Text("Spotify Matching Sources") } footer: {
            Text("Order: local library, then SearXNG (if enabled), then direct YouTube only when SearXNG finds nothing or is unavailable, then manual links. A self-hosted SearXNG only works while the computer running it is on and reachable from this iPhone.")
        }
        .onAppear {
            enabled = settings.searxEnabled; baseURL = settings.searxBaseURL; engines = settings.searxEngines
            allowLAN = settings.allowLANHTTP; directYouTube = settings.directYouTubeEnabled; status = settings.lastHealth
        }
    }
    private func save() {
        settings.searxBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.searxEngines = engines
    }
    private func test() {
        testing = true; status = nil
        Task {
            let result = await SearXNGConnectionTest.run(settings: settings, transport: transport)
            switch result {
            case .success(let health): status = health.summary; statusIsError = false
            case .failure(let error): status = error.localizedDescription; statusIsError = true
            }
            settings.lastHealth = status
            testing = false
        }
    }
}
