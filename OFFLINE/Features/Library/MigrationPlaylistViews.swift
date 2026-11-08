import SwiftUI

struct MigrationPlaylistPlaybackHeader: View {
    @EnvironmentObject private var library: MusicLibraryService
    @Environment(\.scenePhase) private var scenePhase
    let playlistID: String
    var body: some View {
        let rows = library.migrationRows(playlistID)
        let playable = rows.playbackOccurrences
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("\(rows.count) songs • \(playable.count) available offline")
                .font(.caption).foregroundStyle(AppColors.textSecondary).accessibilityIdentifier("migration-playlist-count")
            HStack {
                Button { Task { await library.playMigration(playlistID: playlistID) } } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 36)
                }.buttonStyle(.borderedProminent).tint(AppColors.accentPrimary).foregroundStyle(.black).accessibilityIdentifier("collection-play")
                Button { Task { await library.playMigration(playlistID: playlistID, shuffle: true) } } label: {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity, minHeight: 36)
                }.buttonStyle(.bordered).tint(AppColors.accentPrimary).accessibilityIdentifier("collection-shuffle")
            }.disabled(playable.isEmpty)
            if playable.isEmpty {
                Text(rows.isEmpty ? "This source playlist is empty." : "Source songs are saved. No local audio is available yet.")
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
        }.task { recover() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { recover() } }
    }
    private func recover() { library.perform { try library.storage?.playlistMigrations.recover() } }
}

struct MigrationPlaylistOccurrenceRow: View {
    @EnvironmentObject private var library: MusicLibraryService
    let row: MigrationPlaylistRow
    let playlistID: String
    var body: some View {
        Button { Task { await library.playMigration(playlistID: playlistID, occurrenceID: row.id.uuidString) } } label: {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: row.playableTrack == nil ? "music.note.list" : "play.circle.fill")
                    .foregroundStyle(row.playableTrack == nil ? AppColors.textTertiary : AppColors.accentPrimary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.entry.source.title).foregroundStyle(AppColors.textPrimary)
                    Text(row.entry.source.primaryArtist ?? "Unknown Artist").font(.caption).foregroundStyle(AppColors.textSecondary)
                    if let album = row.entry.source.album { Text(album).font(.caption).foregroundStyle(AppColors.textSecondary) }
                    HStack {
                        Text(row.playableTrack == nil ? row.effectiveStatus.displayName : "Available offline")
                        if let ms = row.entry.source.durationMs { Text("\(ms / 60000):\(String(format: "%02d", (ms / 1000) % 60))") }
                    }.font(.caption2).foregroundStyle(AppColors.textSecondary)
                }
                Spacer()
            }.padding(.vertical, 4)
        }.buttonStyle(.plain).disabled(row.playableTrack == nil)
            .accessibilityIdentifier("migration-occurrence-" + row.id.uuidString)
    }
}

extension PlaylistMigrationEntryStatus {
    var displayName: String {
        switch self {
        case .pending: return "Awaiting local audio"
        case .matching: return "Matching"
        case .needsReview: return "Needs review"
        case .matched: return "Matched"
        case .queued: return "Queued"
        case .downloading: return "Downloading"
        case .verifying: return "Verifying"
        case .ready: return "Available offline"
        case .unavailable: return "Local audio unavailable"
        case .failed: return "Needs attention"
        case .skipped: return "Skipped"
        }
    }
}
