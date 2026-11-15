import SwiftUI

/// Spotify matching sources. Default (Automatic) needs no server: public Invidious,
/// then direct YouTube fallback. Self-hosted SearXNG is an optional advanced source.
struct DiscoverySourcesSettingsView: View {
    let settings: DiscoverySourceSettings
    let transport: any YouTubeTransport
    let pool: InvidiousInstancePool
    @State private var automatic = true
    @State private var invidious = true
    @State private var directYouTube = true
    @State private var searxEnabled = false
    @State private var baseURL = ""
    @State private var engines = ""
    @State private var allowLAN = false
    @State private var instances: [InvidiousInstanceStatus] = []
    @State private var searxStatus: String?
    @State private var searxError = false
    @State private var testing = false
    var body: some View {
        Section {
            Toggle("Automatic Discovery (recommended)", isOn: $automatic)
                .onChange(of: automatic) { _, value in settings.automaticDiscovery = value }
                .accessibilityIdentifier("discovery-automatic")
            Toggle("Public Invidious search", isOn: $invidious).disabled(automatic)
                .onChange(of: invidious) { _, value in settings.invidiousEnabled = value }
            Toggle("Direct YouTube search fallback", isOn: $directYouTube).disabled(automatic)
                .onChange(of: directYouTube) { _, value in settings.directYouTubeEnabled = value }
            Button(testing ? "Testing…" : "Test Discovery Providers") { test() }.disabled(testing)
                .accessibilityIdentifier("discovery-test")
            ForEach(instances) { status in
                Text(status.summary).font(.caption)
                    .foregroundStyle(status.state == .healthy ? AppColors.textSecondary : AppColors.error)
            }
            if !instances.isEmpty {
                let healthy = instances.filter { $0.state == .healthy }.count
                Text(healthy == 0 ? "No public Invidious instance is available right now. Matching will use other enabled sources or manual links."
                                  : "\(healthy) public instance(s) available.").font(.caption)
            }
            DisclosureGroup("Advanced: self-hosted SearXNG") {
                Toggle("Use SearXNG", isOn: $searxEnabled).onChange(of: searxEnabled) { _, value in settings.searxEnabled = value }
                TextField("https://searxng.example.com", text: $baseURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).onSubmit { save() }
                TextField("Video engines", text: $engines).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit { save() }
                Toggle("Allow HTTP on local network (development)", isOn: $allowLAN)
                    .onChange(of: allowLAN) { _, value in settings.allowLANHTTP = value }
                if let searxStatus { Text(searxStatus).font(.caption).foregroundStyle(searxError ? AppColors.error : AppColors.textSecondary) }
            }
        } header: { Text("Spotify Matching Sources") } footer: {
            Text("Order: your local library, public Invidious, optional SearXNG, direct YouTube, then manual links. Song titles and artist names are sent to the third-party services you enable to search for videos. Found videos are candidates only; nothing is downloaded.")
        }
        .onAppear {
            automatic = settings.automaticDiscovery; invidious = settings.invidiousEnabled; directYouTube = settings.directYouTubeEnabled
            searxEnabled = settings.searxEnabled; baseURL = settings.searxBaseURL; engines = settings.searxEngines
            allowLAN = settings.allowLANHTTP; searxStatus = settings.lastHealth
            Task { instances = await pool.statuses }
        }
    }
    private func save() {
        settings.searxBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.searxEngines = engines
    }
    private func test() {
        save(); testing = true
        Task {
            instances = await pool.checkAll()
            if settings.searxEnabled {
                switch await SearXNGConnectionTest.run(settings: settings, transport: transport) {
                case .success(let health): searxStatus = health.summary; searxError = false
                case .failure(let error): searxStatus = error.localizedDescription; searxError = true
                }
                settings.lastHealth = searxStatus
            }
            testing = false
        }
    }
}
