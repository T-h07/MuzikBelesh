import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @State private var showingDiagnostics = false
    @State private var showingTimer = false
    var body: some View { NavigationStack { Form { Section("Playback") { Picker("Audio quality", selection: Binding(get: { container.settings.audioQuality }, set: { container.settings.audioQuality = $0 })) { Text("Standard").tag("Standard"); Text("High").tag("High"); Text("Lossless (mock)").tag("Lossless") }; Toggle("Wi-Fi only downloads", isOn: Binding(get: { container.settings.wifiOnly }, set: { container.settings.wifiOnly = $0 })); Button { showingTimer = true } label: { HStack { Text("Sleep timer"); Spacer(); SleepTimerStatusIndicator(timer: audioPlayer.sleepTimer, showsLabel: true) { showingTimer = true }; if !audioPlayer.sleepTimer.isActive { Text("Off").foregroundStyle(AppColors.textSecondary) } } } }.foregroundStyle(AppColors.textPrimary); Section("Application") { HStack { Text("Version"); Spacer(); Text("\(container.configuration.version) (\(container.configuration.build))").foregroundStyle(AppColors.textSecondary) }; HStack { Text("Bundle ID"); Spacer(); Text(container.configuration.bundleIdentifier).font(.caption).foregroundStyle(AppColors.textSecondary) }; Button("Phase 0 Diagnostics") { showingDiagnostics = true } }; Section { Text("Muzik Belesh uses mock data in Phase 1. No settings persist after force quit.").font(.caption).foregroundStyle(AppColors.textSecondary) } }.scrollContentBackground(.hidden).background(AppColors.backgroundPrimary).navigationTitle("Settings").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }.sheet(isPresented: $showingDiagnostics) { DiagnosticsView(viewModel: DiagnosticsViewModel(container: container)) }.sheet(isPresented: $showingTimer) { SleepTimerSheet(timer: audioPlayer.sleepTimer).presentationDetents([.height(390)]) } } }
}

