import SwiftUI

/// "Your Listening": device-local listening statistics opened from the Profile page.
/// Every value comes from `ListeningStatsService`; nothing is sampled, estimated or invented.
struct ListeningDashboardView: View {
    @Environment(\.themePalette) private var palette
    @EnvironmentObject private var stats: ListeningStatsService
    @EnvironmentObject private var profile: LocalProfileService
    @EnvironmentObject private var library: MusicLibraryService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var range: ListeningRange = .last7
    /// The last summary shown, kept on screen (dimmed) while another range loads.
    @State private var lastShown: ListeningSummary?
    @State private var playedTrigger = 0

    private var current: ListeningSummary? { stats.summary(range) }
    private var shown: ListeningSummary? { current ?? lastShown }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                header
                ListeningRangePicker(range: $range)
                content
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, 48)
        }
        .screenBackground()
        .navigationTitle("Your Listening")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { stats.load(range) }
        .onAppear { stats.load(range) }
        .onChange(of: range) { _, newRange in stats.load(newRange) }
        .onChange(of: current) { _, value in if let value { lastShown = value } }
        .sensoryFeedback(.impact(weight: .light), trigger: playedTrigger)
    }

    private var header: some View {
        HStack(spacing: AppSpacing.md) {
            ProfileAvatarView(size: 44).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                ListeningStyle.eyebrow(profile.profile?.username ?? "Your Profile")
                Text("Your music story").font(.system(size: 28, weight: .bold)).foregroundStyle(AppColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var content: some View {
        if let summary = shown {
            Group {
                if !summary.hasAnyListening { firstRun(summary) }
                else { dashboard(summary) }
            }
            .opacity(current == nil ? 0.55 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: current == nil)
        } else if let failure = stats.failure(range) {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text("Something went wrong").font(.title3.weight(.semibold)).foregroundStyle(AppColors.textPrimary)
                Text(failure).font(.subheadline).foregroundStyle(AppColors.textSecondary).accessibilityIdentifier("listening-error")
                Button("Try Again") { stats.load(range) }
                    .font(.headline).foregroundStyle(palette.onAccent).padding(.horizontal, AppSpacing.xl).frame(minHeight: 44)
                    .background(Capsule().fill(palette.accent)).accessibilityIdentifier("listening-retry")
            }
        } else {
            skeleton
        }
    }

    // MARK: States

    private func firstRun(_ summary: ListeningSummary) -> some View {
        VStack(alignment: .leading, spacing: 40) {
            VStack(spacing: AppSpacing.lg) {
                ZStack {
                    ForEach(0..<3) { index in Circle().stroke(ListeningStyle.track, lineWidth: 3).padding(CGFloat(index) * 16) }
                    Image(systemName: "waveform").font(.system(size: 38, weight: .light)).foregroundStyle(palette.accent)
                }
                .frame(width: 180, height: 180).accessibilityHidden(true)
                Text("Your listening story starts here.").font(.title2.weight(.bold)).foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.center).accessibilityIdentifier("listening-empty-title")
                Text("Play some music and your listening time, top songs, artists and playlists will appear here.")
                    .font(.subheadline).foregroundStyle(AppColors.textSecondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            libraryOverview(summary.library)
            footer(summary)
        }
    }

    private func dashboard(_ summary: ListeningSummary) -> some View {
        VStack(alignment: .leading, spacing: 44) {
            ListeningHero(summary: summary)
                .animation(reduceMotion ? nil : .snappy(duration: 0.45), value: summary.listenedMs)
            if summary.isEmpty {
                Text("No listening in the \(summary.range.title.lowercased()) yet.")
                    .font(.subheadline).foregroundStyle(AppColors.textSecondary).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("listening-range-empty")
            } else {
                statStrip(summary)
                ListeningActivityChart(summary: summary)
                highlights(summary)
                if !summary.topSongs.isEmpty { TopSongsSection(songs: summary.topSongs, play: play) }
                if !summary.topArtists.isEmpty { TopArtistsSection(artists: summary.topArtists) { ArtistDetailView(groupID: $0.id) } }
                if !summary.topAlbums.isEmpty {
                    TopCollectionsCarousel(title: "Top Albums", items: summary.topAlbums, showsPlays: false, identifier: "listening-top-album") { AlbumDetailView(groupID: $0.id) }
                }
                if !summary.topPlaylists.isEmpty {
                    TopCollectionsCarousel(title: "Top Playlists", items: summary.topPlaylists, showsPlays: true, identifier: "listening-top-playlist") { PlaylistDetailView(playlistID: $0.id) }
                }
            }
            libraryOverview(summary.library)
            footer(summary)
        }
    }

    private var skeleton: some View {
        VStack(spacing: AppSpacing.xl) {
            Circle().stroke(ListeningStyle.track, lineWidth: 3).frame(width: 220, height: 220)
            RoundedRectangle(cornerRadius: AppRadius.small).fill(ListeningStyle.track).frame(height: 160)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading listening activity")
        .accessibilityIdentifier("listening-loading")
    }

    // MARK: Sections

    /// Three typographic figures separated by hairlines — deliberately not a grid of cards.
    private func statStrip(_ summary: ListeningSummary) -> some View {
        let active = ListeningChartModel.activeDays(summary).active
        let average = active == 0 ? 0 : summary.listenedMs / Int64(active)
        return HStack(spacing: 0) {
            figure(summary.uniqueSongs.formatted(), label: summary.uniqueSongs == 1 ? "song" : "songs", identifier: "listening-unique-songs")
            hairline
            figure(ListeningFormat.duration(average), label: "per active day", identifier: "listening-daily-average")
            hairline
            figure(ListeningFormat.duration(summary.longestSessionMs), label: "longest session", identifier: "listening-longest-session")
        }
    }

    private var hairline: some View { Rectangle().fill(AppColors.divider).frame(width: 1, height: 40) }

    private func figure(_ value: String, label: String, identifier: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit().foregroundStyle(AppColors.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6).contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(AppColors.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    /// Verifiable observations only, each shown only when its data exists.
    @ViewBuilder private func highlights(_ summary: ListeningSummary) -> some View {
        let busiest = summary.busiestDay
        let replayed = summary.mostReplayed
        if busiest != nil || replayed != nil {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                if let busiest, let date = ListeningDayKey(calendar: .current).date(for: busiest.day) {
                    highlight("Your busiest listening day",
                              value: date.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                              detail: ListeningFormat.duration(busiest.listenedMs), identifier: "listening-busiest-day")
                }
                if let replayed {
                    highlight("Most replayed track", value: replayed.title, detail: "\(ListeningFormat.plays(replayed.plays)) · \(replayed.artistName)", identifier: "listening-most-replayed")
                }
            }
        }
    }

    private func highlight(_ title: String, value: String, detail: String, identifier: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            Capsule().fill(palette.accent).frame(width: 3).frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(AppColors.textTertiary)
                Text(value).font(.title3.weight(.semibold)).foregroundStyle(AppColors.textPrimary).lineLimit(2)
                Text(detail).font(.subheadline).foregroundStyle(AppColors.textSecondary).lineLimit(1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func libraryOverview(_ overview: LibraryOverview) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            ListeningStyle.eyebrow("Your Library")
            Grid(alignment: .leading, horizontalSpacing: AppSpacing.lg, verticalSpacing: AppSpacing.lg) {
                GridRow {
                    libraryFigure(overview.songs.formatted(), label: "Songs", identifier: "listening-library-songs")
                    libraryFigure(overview.availableOffline.formatted(), label: "Available offline", identifier: "listening-library-offline")
                }
                Divider().overlay(AppColors.divider).gridCellColumns(2)
                GridRow {
                    libraryFigure(overview.playlists.formatted(), label: "Playlists", identifier: "listening-library-playlists")
                    libraryFigure(ListeningFormat.bytes(overview.storageBytes), label: "Storage used", identifier: "listening-library-storage")
                }
            }
            .padding(AppSpacing.lg)
            .background(AppColors.backgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        }
    }

    private func libraryFigure(_ value: String, label: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline).monospacedDigit().foregroundStyle(AppColors.textPrimary)
            Text(label).font(.caption).foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func footer(_ summary: ListeningSummary) -> some View {
        let since = summary.trackingStartedAt.map { " from \($0.formatted(date: .abbreviated, time: .omitted))" } ?? " from this update"
        return Text("Accurate listening time is tracked\(since). Earlier playback isn't included. Your statistics stay on this iPhone.")
            .font(.caption).foregroundStyle(AppColors.textTertiary)
            .accessibilityIdentifier("listening-tracking-note")
    }

    private func play(_ song: RankedSong) {
        guard song.isAvailable else { return }
        playedTrigger += 1
        let ids = (current?.topSongs ?? []).filter(\.isAvailable).map(\.trackID)
        Task { await library.play(song.trackID, ids: ids.isEmpty ? [song.trackID] : ids, kind: "listeningStats") }
    }
}
