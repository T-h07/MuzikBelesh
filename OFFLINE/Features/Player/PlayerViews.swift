import SwiftUI

struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var container: AppContainer
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        NavigationStack {
            VStack(spacing: AppSpacing.xl) {
                content
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.bottom, AppSpacing.xxl)
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .screenBackground()
        }
    }

    @ViewBuilder private var content: some View {
        if let id = container.playback.currentTrackID, let track = container.music.track(id) {
            ArtworkView(name: track.artwork, size: 320).padding(.top, AppSpacing.xxl)
            VStack(spacing: AppSpacing.sm) {
                Text(track.title).font(.title2.bold()).foregroundStyle(AppColors.textPrimary)
                Text(track.artist).foregroundStyle(AppColors.textSecondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Slider(value: Binding(get: { container.playback.position }, set: { container.playback.seek($0, duration: track.duration) }), in: 0...track.duration).tint(AppColors.accentPrimary)
            HStack { Text("0:00"); Spacer(); Text(format(track.duration)) }.font(.caption).foregroundStyle(AppColors.textSecondary)
            HStack(spacing: 38) {
                Button { container.playback.previous() } label: { Image(systemName: "backward.fill").font(.title2) }
                Button { container.playback.togglePlayPause() } label: { Image(systemName: container.playback.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 58)) }
                Button { container.playback.next() } label: { Image(systemName: "forward.fill").font(.title2) }
            }.foregroundStyle(AppColors.textPrimary)
            HStack {
                Button { container.playback.shuffleEnabled.toggle() } label: { Image(systemName: "shuffle").foregroundStyle(container.playback.shuffleEnabled ? AppColors.accentPrimary : AppColors.textSecondary) }
                Spacer()
                Button { coordinator.sheet = .sleepTimer } label: { Image(systemName: "timer").foregroundStyle(AppColors.textSecondary) }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "list.bullet").foregroundStyle(AppColors.textSecondary) }.accessibilityLabel("Up Next")
            }
        } else {
            EmptyState(icon: "music.note", title: "Nothing playing", message: "Choose a mock track first.")
        }
    }
    private func format(_ seconds: TimeInterval) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}

struct QueueView: View {
    @EnvironmentObject private var container: AppContainer
    var body: some View {
        List {
            ForEach(container.playback.queueIDs, id: \.self) { id in
                if let track = container.music.track(id) { TrackRow(track: track).listRowBackground(AppColors.backgroundPrimary) }
            }
            .onDelete { container.playback.removeFromQueue(at: $0) }
            .onMove { container.playback.queueIDs.move(fromOffsets: $0, toOffset: $1) }
        }.scrollContentBackground(.hidden).background(AppColors.backgroundPrimary).navigationTitle("Up Next")
    }
}

struct SleepTimerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var container: AppContainer
    let options = ["Off", "15 minutes", "30 minutes", "45 minutes", "60 minutes"]
    var body: some View { NavigationStack { List { ForEach(options, id: \.self) { option in Button { container.settings.sleepTimer = option; dismiss() } label: { HStack { Text(option).foregroundStyle(AppColors.textPrimary); Spacer(); if container.settings.sleepTimer == option { Image(systemName: "checkmark").foregroundStyle(AppColors.accentPrimary) } } } } }.scrollContentBackground(.hidden).background(AppColors.backgroundPrimary).navigationTitle("Sleep Timer").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } } } }
}

