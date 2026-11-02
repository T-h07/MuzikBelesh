import SwiftUI

struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @ObservedObject var coordinator: AppCoordinator
    @State private var showingQueue = false

    private var track: StoredTrack? { guard let storage = container.storage, let id = audioPlayer.state.currentTrackID else { return nil }; return try? storage.tracks.find(id: id) }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView { VStack(spacing: AppSpacing.lg) { content }.frame(minHeight: proxy.size.height, alignment: .center).padding(.vertical, AppSpacing.md) }
            }
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
            StoredArtworkView(track: track, size: min(280, max(180, UIScreen.main.bounds.width - 64))).frame(maxWidth: .infinity)
            VStack(spacing: AppSpacing.sm) {
                Text(track.title).font(.title2.bold()).foregroundStyle(AppColors.textPrimary)
                Text(track.originalFilename ?? "Local Music").foregroundStyle(AppColors.textSecondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            PlaybackSlider(audioPlayer: audioPlayer)
            HStack { Text(format(audioPlayer.state.elapsedTime)); Spacer(); Text(format(audioPlayer.state.duration)) }.font(.caption).foregroundStyle(AppColors.textSecondary)
            HStack(spacing: 38) {
                Button { Task { await audioPlayer.previous() } } label: { Image(systemName: "backward.fill").font(.title2).frame(width: 52, height: 52) }
                Button { Task { await audioPlayer.togglePlayback() } } label: { Image(systemName: audioPlayer.state.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 58)) }
                Button { Task { await audioPlayer.next() } } label: { Image(systemName: "forward.fill").font(.title2).frame(width: 52, height: 52) }
            }.foregroundStyle(AppColors.textPrimary)
            HStack {
                Text(audioPlayer.state.currentOutputRoute).font(.caption).foregroundStyle(AppColors.textTertiary).lineLimit(1)
                Spacer()
                Button { showingQueue = true } label: { Image(systemName: "list.bullet").foregroundStyle(AppColors.textSecondary) }.accessibilityLabel("Up Next")
            }
            if case .failed(let message) = audioPlayer.state.status { Text(message).font(.caption).foregroundStyle(AppColors.error).multilineTextAlignment(.center) }
            Text("Shuffle, repeat, and sleep timer arrive in Phase 4.").font(.caption2).foregroundStyle(AppColors.textTertiary).multilineTextAlignment(.center)
        } else {
            EmptyState(icon: "music.note", title: "Nothing playing", message: "Import a local audio file from Library first.")
        }
    }
    private func format(_ seconds: TimeInterval) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}

private struct PlaybackSlider: View {
    @ObservedObject var audioPlayer: AudioPlayerService
    @State private var draftPosition: TimeInterval?
    var body: some View {
        let duration = max(audioPlayer.state.duration, 0.01)
        Slider(value: Binding(get: { draftPosition ?? audioPlayer.state.elapsedTime }, set: { draftPosition = min(max($0, 0), duration) }), in: 0...duration, onEditingChanged: { editing in
            if !editing, let draftPosition { Task { await audioPlayer.seek(to: draftPosition) }; self.draftPosition = nil }
        }).tint(AppColors.accentPrimary).disabled(!audioPlayer.state.canSeek)
    }
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

