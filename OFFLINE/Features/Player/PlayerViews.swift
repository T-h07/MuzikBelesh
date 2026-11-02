import SwiftUI

struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var container: AppContainer
    @ObservedObject var coordinator: AppCoordinator
    @State private var showingQueue = false

    private var track: StoredTrack? { guard let storage = container.storage, let id = container.audioPlayer.state.currentTrackID else { return nil }; return try? storage.tracks.find(id: id) }

    var body: some View {
        NavigationStack {
            VStack(spacing: AppSpacing.xl) { content }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.bottom, AppSpacing.xxl)
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .screenBackground()
            .sheet(isPresented: $showingQueue) { NavigationStack { QueueView() } }
        }
    }

    @ViewBuilder private var content: some View {
        if let track {
            ArtworkView(name: "music-note", size: 320).padding(.top, AppSpacing.xxl)
            VStack(spacing: AppSpacing.sm) {
                Text(track.title).font(.title2.bold()).foregroundStyle(AppColors.textPrimary)
                Text(track.originalFilename ?? "Local Music").foregroundStyle(AppColors.textSecondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Slider(value: Binding(get: { container.audioPlayer.state.elapsedTime }, set: { value in Task { await container.audioPlayer.seek(to: value) } }), in: 0...max(container.audioPlayer.state.duration, 0.01)).tint(AppColors.accentPrimary).disabled(!container.audioPlayer.state.canSeek)
            HStack { Text(format(container.audioPlayer.state.elapsedTime)); Spacer(); Text(format(container.audioPlayer.state.duration)) }.font(.caption).foregroundStyle(AppColors.textSecondary)
            HStack(spacing: 38) {
                Button { Task { await container.audioPlayer.previous() } } label: { Image(systemName: "backward.fill").font(.title2) }
                Button { Task { await container.audioPlayer.togglePlayback() } } label: { Image(systemName: container.audioPlayer.state.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 58)) }
                Button { Task { await container.audioPlayer.next() } } label: { Image(systemName: "forward.fill").font(.title2) }
            }.foregroundStyle(AppColors.textPrimary)
            HStack {
                Text(container.audioPlayer.state.currentOutputRoute).font(.caption).foregroundStyle(AppColors.textTertiary).lineLimit(1)
                Spacer()
                Button { showingQueue = true } label: { Image(systemName: "list.bullet").foregroundStyle(AppColors.textSecondary) }.accessibilityLabel("Up Next")
            }
            if case .failed(let message) = container.audioPlayer.state.status { Text(message).font(.caption).foregroundStyle(AppColors.error).multilineTextAlignment(.center) }
            Text("Shuffle, repeat, and sleep timer arrive in Phase 4.").font(.caption2).foregroundStyle(AppColors.textTertiary).multilineTextAlignment(.center)
        } else {
            EmptyState(icon: "music.note", title: "Nothing playing", message: "Import a local audio file from Library first.")
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

