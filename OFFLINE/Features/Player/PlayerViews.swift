import SwiftUI

struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @EnvironmentObject private var library: MusicLibraryService
    @ObservedObject var coordinator: AppCoordinator
    @State private var showingQueue = false
    @State private var showingTimer = false

    private var track: StoredTrack? { library.track(audioPlayer.state.currentTrackID) }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView { VStack(spacing: proxy.size.height < 650 ? AppSpacing.md : AppSpacing.lg) { content(availableSize: proxy.size) }.frame(minHeight: proxy.size.height, alignment: .center).padding(.vertical, AppSpacing.md) }
            }
            .padding(.horizontal, AppSpacing.lg)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: AppSpacing.sm) }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .screenBackground()
            .sheet(isPresented: $showingQueue) { NavigationStack { QueueView() } }
            .sheet(isPresented: $showingTimer) { SleepTimerSheet(timer: audioPlayer.sleepTimer).presentationDetents([.height(390)]) }
        }
    }

    @ViewBuilder private func content(availableSize: CGSize) -> some View {
        if let track {
            let artworkSize = min(availableSize.width, max(availableSize.width * 0.72, min(availableSize.width - 24, availableSize.height * 0.38)))
            StoredArtworkView(track: track, size: artworkSize).frame(maxWidth: .infinity)
            VStack(spacing: AppSpacing.sm) {
                Text(track.title).font(.title2.bold()).foregroundStyle(AppColors.textPrimary).lineLimit(2).minimumScaleFactor(0.85).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                Text(artistAndAlbum(for: track)).font(.body).foregroundStyle(AppColors.textSecondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button {
                library.perform { try library.setLiked(!library.snapshot.likedIDs.contains(track.id), trackID: track.id) }
            } label: { Label(library.snapshot.likedIDs.contains(track.id) ? "Unlike Song" : "Like Song", systemImage: library.snapshot.likedIDs.contains(track.id) ? "heart.fill" : "heart").frame(minHeight: 44) }
                .foregroundStyle(AppColors.accentPrimary).accessibilityIdentifier("now-playing-like")
            PlaybackSlider(audioPlayer: audioPlayer)
            HStack { Text(format(audioPlayer.state.elapsedTime)); Spacer(); Text(format(audioPlayer.state.duration)) }.font(.caption).foregroundStyle(AppColors.textSecondary)
            if audioPlayer.state.status == .ended {
                Text("Playback complete. Play restarts this song; Next starts a new shuffle cycle when Shuffle is on.")
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
            HStack(spacing: availableSize.width < 360 ? 24 : 40) {
                Button { Task { await audioPlayer.previous() } } label: { Image(systemName: "backward.fill").font(.title2).frame(width: 52, height: 52) }.disabled(!audioPlayer.state.canSkipPrevious).accessibilityLabel("Previous track")
                Button { Task { await audioPlayer.togglePlayback() } } label: { Image(systemName: audioPlayer.state.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 58)).frame(width: 64, height: 64) }.accessibilityLabel(audioPlayer.state.isPlaying ? "Pause" : "Play")
                Button { Task { await audioPlayer.next() } } label: { Image(systemName: "forward.fill").font(.title2).frame(width: 52, height: 52) }.disabled(!audioPlayer.state.canSkipNext).accessibilityLabel("Next track")
            }.foregroundStyle(AppColors.textPrimary)
            HStack(spacing: AppSpacing.lg) {
                Button { audioPlayer.queue.toggleShuffle() } label: { Image(systemName: "shuffle").foregroundStyle(audioPlayer.queue.shuffleEnabled ? AppColors.accentPrimary : AppColors.textSecondary) }.frame(minWidth: 44, minHeight: 44).accessibilityLabel("Shuffle").accessibilityValue(audioPlayer.queue.shuffleEnabled ? "On" : "Off")
                Button { audioPlayer.queue.cycleRepeat() } label: { Image(systemName: audioPlayer.queue.repeatMode.symbol).foregroundStyle(audioPlayer.queue.repeatMode == .off ? AppColors.textSecondary : AppColors.accentPrimary) }.frame(minWidth: 44, minHeight: 44).accessibilityLabel("Repeat \(audioPlayer.queue.repeatMode.rawValue)")
                Button { showingTimer = true } label: { Image(systemName: audioPlayer.sleepTimer.isActive ? "moon.fill" : "moon").foregroundStyle(audioPlayer.sleepTimer.isActive ? AppColors.accentPrimary : AppColors.textSecondary) }.frame(minWidth: 44, minHeight: 44).accessibilityLabel("Sleep Timer")
            }
            SleepTimerStatusIndicator(timer: audioPlayer.sleepTimer, showsLabel: true) { showingTimer = true }
            HStack {
                Text(audioPlayer.state.currentOutputRoute).font(.caption).foregroundStyle(AppColors.textTertiary).lineLimit(1)
                Spacer()
                Button { showingQueue = true } label: { Image(systemName: "list.bullet").foregroundStyle(AppColors.textSecondary) }.accessibilityLabel("Up Next")
            }
            if let message = audioPlayer.state.lastError { Text(message).font(.caption).foregroundStyle(AppColors.error).multilineTextAlignment(.center) }
        } else {
            EmptyState(icon: "music.note", title: "Nothing playing", message: "Import a local audio file from Library first.")
        }
    }
    private func artistAndAlbum(for track: StoredTrack) -> String {
        let artist = container.storage?.artistName(for: track.artistID)
        let album = container.storage?.albumTitle(for: track.albumID)
        return [artist, album].compactMap { $0 }.joined(separator: " • ").ifEmpty("Local Music")
    }
    private func format(_ seconds: TimeInterval) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
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
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @EnvironmentObject private var library: MusicLibraryService
    var body: some View {
        List {
            if audioPlayer.queue.entries.isEmpty {
                Text("Nothing queued. Add songs with Add to Queue or Play Next.").foregroundStyle(AppColors.textSecondary).listRowBackground(AppColors.backgroundPrimary)
            }
            ForEach(audioPlayer.queue.entries) { entry in
                if let track = track(for: entry.trackID) { StoredQueueRow(track: track, origin: entry.origin).listRowBackground(AppColors.backgroundPrimary) }
            }
            .onDelete { audioPlayer.queue.remove(at: $0) }
            .onMove { audioPlayer.queue.move(from: $0, to: $1) }
        }.toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Clear") { audioPlayer.queue.clear() }.disabled(audioPlayer.queue.entries.isEmpty) } }.scrollContentBackground(.hidden).background(AppColors.backgroundPrimary).navigationTitle("Up Next")
    }
    private func track(for id: String) -> StoredTrack? { library.track(id) }
}

private struct StoredQueueRow: View {
    let track: StoredTrack
    let origin: QueueEntryOrigin
    var body: some View { HStack(spacing: AppSpacing.md) { StoredArtworkView(track: track, size: 48); VStack(alignment: .leading) { Text(track.title).foregroundStyle(AppColors.textPrimary).lineLimit(1); Text(origin == .playNext ? "Play Next" : "Queued").font(.caption).foregroundStyle(AppColors.textSecondary) }; Spacer() } }
}

private struct LegacySleepTimerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var container: AppContainer
    let options = [0, 5, 10, 15, 30, 45, 60]
    var body: some View { NavigationStack { List { ForEach(options, id: \.self) { minutes in Button { if minutes == 0 { container.audioPlayer.sleepTimer.cancel() } else { container.audioPlayer.sleepTimer.start(minutes: minutes) }; dismiss() } label: { HStack { Text(minutes == 0 ? "Off" : "\(minutes) minutes").foregroundStyle(AppColors.textPrimary); Spacer(); if (minutes == 0 && !container.audioPlayer.sleepTimer.isActive) || (minutes > 0 && container.audioPlayer.sleepTimer.remaining > TimeInterval(minutes * 60 - 5)) { Image(systemName: "checkmark").foregroundStyle(AppColors.accentPrimary) } } } } }.scrollContentBackground(.hidden).background(AppColors.backgroundPrimary).navigationTitle("Sleep Timer").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } } } }
}

