import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @State private var showingDiagnostics = false
    @State private var showingTimer = false
    var body: some View { NavigationStack { Form { Section("Playback") { YouTubeQualitySetting(preferences: container.youtubePreferences); Button { showingTimer = true } label: { HStack { Text("Sleep timer"); Spacer(); SleepTimerStatusIndicator(timer: audioPlayer.sleepTimer, showsLabel: true) { showingTimer = true }; if !audioPlayer.sleepTimer.isActive { Text("Off").foregroundStyle(AppColors.textSecondary) } } } }.foregroundStyle(AppColors.textPrimary); Section("Application") { HStack { Text("Version"); Spacer(); Text("\(container.configuration.version) (\(container.configuration.build))").foregroundStyle(AppColors.textSecondary) }; HStack { Text("Commit"); Spacer(); Text(container.configuration.commit).font(.caption).foregroundStyle(AppColors.textSecondary) }; HStack { Text("Build date"); Spacer(); Text(container.configuration.buildDate).font(.caption).foregroundStyle(AppColors.textSecondary) }; HStack { Text("Bundle ID"); Spacer(); Text(container.configuration.bundleIdentifier).font(.caption).foregroundStyle(AppColors.textSecondary) }; Button("Diagnostics") { showingDiagnostics = true } }; Section { Text("Imported music, playback queue and Sleep Timer are saved. YouTube audio quality is saved.").font(.caption).foregroundStyle(AppColors.textSecondary) } }.scrollContentBackground(.hidden).background(AppColors.backgroundPrimary).navigationTitle("Settings").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }.sheet(isPresented: $showingDiagnostics) { DiagnosticsView(viewModel: DiagnosticsViewModel(container: container)) }.sheet(isPresented: $showingTimer) { SleepTimerSheet(timer: audioPlayer.sleepTimer).presentationDetents([.height(390)]) } } }
}

private struct YouTubeQualitySetting: View {
    @ObservedObject var preferences: YouTubePreferences
    var body: some View {
        Toggle("Wi-Fi only for audio downloads", isOn: $preferences.wifiOnly).accessibilityIdentifier("downloads-wifi")
        Picker("Simultaneous downloads", selection: $preferences.simultaneous) {
            ForEach(1...3, id: \.self) { Text(String($0)).tag($0) }
        }.accessibilityIdentifier("downloads-limit")
        Text("Quality choices may use the same stream when only one compatible format is available.").font(.caption)
        Picker("YouTube Audio Quality", selection: $preferences.quality) {
            ForEach(AudioQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.accessibilityIdentifier("settings-youtube-quality")
    }
}
