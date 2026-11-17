import Charts
import SwiftUI

/// Analytics styling. Every color comes from the central design system so the Phase 11.3
/// accent theme can replace `accent` in one place.
enum ListeningStyle {
    static var accent: Color { AppColors.accentPrimary }
    static var track: Color { AppColors.textPrimary.opacity(0.08) }
    static let heroFont: CGFloat = 60
    static func eyebrow(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption2.weight(.semibold)).tracking(1.4).foregroundStyle(AppColors.textTertiary)
    }
}

// MARK: Hero

/// Total listening time over three thin rings, each a real ratio from the summary:
/// active days in the range, qualified share of playback starts, completed share of
/// qualified plays. The rings draw in once when the data changes; nothing loops.
struct ListeningHero: View {
    let summary: ListeningSummary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = ListeningStyle.heroFont
    @State private var drawn = false

    private var active: (active: Int, total: Int) { ListeningChartModel.activeDays(summary) }
    private var rings: [(fraction: Double, opacity: Double)] {
        let days = Double(active.active) / Double(max(active.total, 1))
        let qualified = summary.playbackStarts == 0 ? 0 : Double(summary.qualifiedPlays) / Double(summary.playbackStarts)
        let completed = summary.qualifiedPlays == 0 ? 0 : Double(summary.completedPlays) / Double(summary.qualifiedPlays)
        return [(days, 1), (qualified, 0.6), (completed, 0.32)]
    }

    var body: some View {
        VStack(spacing: AppSpacing.xl) {
            ZStack {
                ForEach(Array(rings.enumerated()), id: \.offset) { index, ring in
                    let inset = CGFloat(index) * 16
                    Circle().stroke(ListeningStyle.track, lineWidth: 3).padding(inset)
                    Circle().trim(from: 0, to: drawn ? min(max(ring.fraction, 0), 1) : 0)
                        .stroke(ListeningStyle.accent.opacity(ring.opacity), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(inset)
                }
                VStack(spacing: 2) {
                    Text(ListeningFormat.duration(summary.listenedMs))
                        .font(.system(size: heroSize, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(AppColors.textPrimary)
                        .contentTransition(.numericText())
                        .lineLimit(1).minimumScaleFactor(0.4)
                        .accessibilityIdentifier("listening-total-time")
                    Text("Total Time Listening").font(.subheadline.weight(.medium)).foregroundStyle(AppColors.textSecondary)
                }
                .padding(.horizontal, 56)
            }
            .frame(maxWidth: 330).aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Total time listening, \(summary.range.title)")
            .accessibilityValue(ListeningFormat.spokenDuration(summary.listenedMs))
            .accessibilityIdentifier("listening-hero")

            HStack(alignment: .top, spacing: AppSpacing.lg) {
                legend(opacity: 1, value: "\(active.active)/\(active.total)", label: "days active")
                legend(opacity: 0.6, value: summary.qualifiedPlays.formatted(), label: "of \(summary.playbackStarts.formatted()) starts counted as plays")
                legend(opacity: 0.32, value: summary.completedPlays.formatted(), label: "played to the end")
            }
        }
        .onAppear { animateRings() }
        .onChange(of: summary) { _, _ in
            if reduceMotion { drawn = true } else { drawn = false; animateRings() }
        }
    }

    private func animateRings() {
        guard !reduceMotion else { drawn = true; return }
        withAnimation(.easeOut(duration: 0.9).delay(0.05)) { drawn = true }
    }

    private func legend(opacity: Double, value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Capsule().fill(ListeningStyle.accent.opacity(opacity)).frame(width: 14, height: 3)
                Text(value).font(.headline).monospacedDigit().foregroundStyle(AppColors.textPrimary)
            }
            Text(label).font(.caption).foregroundStyle(AppColors.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Range picker

struct ListeningRangePicker: View {
    @Binding var range: ListeningRange
    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ListeningRange.allCases) { option in
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) { range = option }
                } label: {
                    Text(option.shortTitle).font(.subheadline.weight(.semibold))
                        .foregroundStyle(range == option ? Color.black : AppColors.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background {
                            if range == option { Capsule().fill(ListeningStyle.accent).matchedGeometryEffect(id: "range", in: selection) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(range == option ? .isSelected : [])
                .accessibilityIdentifier("listening-range-\(option.rawValue)")
            }
        }
        .padding(4)
        .background(Capsule().fill(AppColors.backgroundSecondary))
        .sensoryFeedback(.selection, trigger: range)
    }
}

// MARK: Activity chart

/// Swift Charts bars with rounded ends, a fine dashed grid and drag-to-inspect selection.
struct ListeningActivityChart: View {
    let summary: ListeningSummary
    @State private var selected: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let model = ListeningChartModel.buckets(for: summary)
        chart(granularity: model.0, buckets: model.1)
    }

    private func chart(granularity: ListeningChartModel.Granularity, buckets: [ListeningChartModel.Bucket]) -> some View {
        let selectedBucket = selected.flatMap { date in
            ListeningChartModel.bucketStart(date, granularity, .current).flatMap { start in buckets.first { $0.start == start } }
        }
        return VStack(alignment: .leading, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                ListeningStyle.eyebrow("Listening Activity")
                Group {
                    if let selectedBucket {
                        Text("\(ListeningChartModel.label(for: selectedBucket.start, granularity: granularity, range: summary.range)) — \(ListeningFormat.duration(selectedBucket.listenedMs))")
                    } else {
                        Text(caption(granularity: granularity, buckets: buckets))
                    }
                }
                .font(.title3.weight(.semibold)).foregroundStyle(AppColors.textPrimary)
                .contentTransition(.opacity)
                .accessibilityIdentifier("listening-chart-callout")
            }
            Chart(buckets) { bucket in
                BarMark(x: .value("Date", bucket.start, unit: ListeningChartModel.component(granularity)),
                        y: .value("Minutes", bucket.minutes))
                    .cornerRadius(4)
                    .foregroundStyle(ListeningStyle.accent.opacity(selectedBucket == nil || selectedBucket?.start == bucket.start ? 1 : 0.32))
                    .accessibilityLabel(ListeningChartModel.label(for: bucket.start, granularity: granularity, range: summary.range))
                    .accessibilityValue(ListeningFormat.spokenDuration(bucket.listenedMs))
                if let selectedBucket, selectedBucket.start == bucket.start {
                    RuleMark(x: .value("Date", bucket.start, unit: ListeningChartModel.component(granularity)))
                        .foregroundStyle(AppColors.textPrimary.opacity(0.18))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartXSelection(value: $selected)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(AppColors.divider)
                    AxisValueLabel {
                        if let minutes = value.as(Double.self) { Text(ListeningFormat.duration(Int64(minutes * 60_000))) }
                    }.foregroundStyle(AppColors.textTertiary)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: summary.range == .last7 ? 7 : 5)) { _ in
                    AxisValueLabel(format: axisFormat(granularity), centered: granularity == .day && summary.range == .last7)
                        .foregroundStyle(AppColors.textTertiary)
                }
            }
            .frame(height: 190)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: buckets)
            .accessibilityIdentifier("listening-activity-chart")
        }
        .onChange(of: summary.range) { _, _ in selected = nil }
        .sensoryFeedback(.selection, trigger: selectedBucket?.start)
    }

    private func axisFormat(_ granularity: ListeningChartModel.Granularity) -> Date.FormatStyle {
        switch granularity {
        case .day: return summary.range == .last7 ? .dateTime.weekday(.narrow) : .dateTime.day().month(.abbreviated)
        case .week: return .dateTime.day().month(.abbreviated)
        case .month: return .dateTime.month(.abbreviated)
        }
    }

    private func caption(granularity: ListeningChartModel.Granularity, buckets: [ListeningChartModel.Bucket]) -> String {
        guard !buckets.isEmpty else { return "No listening yet" }
        let total = buckets.reduce(Int64(0)) { $0 + $1.listenedMs }
        let average = total / Int64(buckets.count)
        switch granularity {
        case .day: return "\(ListeningFormat.duration(average)) a day on average"
        case .week: return "\(ListeningFormat.duration(average)) a week on average"
        case .month: return "\(ListeningFormat.duration(average)) a month on average"
        }
    }
}

// MARK: Rankings

/// A proportional bar plus the value in text, so rankings never rely on color alone.
struct ListeningShareBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(ListeningStyle.track)
                Capsule().fill(ListeningStyle.accent.opacity(0.85)).frame(width: max(4, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

struct ListeningRankNumber: View {
    let rank: Int
    var size: CGFloat = 22
    var body: some View {
        Text("\(rank)").font(.system(size: size, weight: .bold, design: .rounded)).monospacedDigit()
            .foregroundStyle(rank == 1 ? ListeningStyle.accent : AppColors.textTertiary)
            .frame(minWidth: size, alignment: .leading)
            .accessibilityHidden(true)
    }
}

/// Top Songs: the number-one song is presented editorially with large artwork; the rest
/// form a compact ranked list. Tapping an available song plays it; unavailable songs say so.
struct TopSongsSection: View {
    let songs: [RankedSong]
    let play: (RankedSong) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            ListeningStyle.eyebrow("Top Songs")
            if let first = songs.first {
                Button { play(first) } label: { featured(first) }
                    .buttonStyle(ListeningPressStyle())
                    .disabled(!first.isAvailable)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label(first, rank: 1))
                    .accessibilityHint(first.isAvailable ? "Plays this song" : "")
                    .accessibilityIdentifier("listening-top-song-1")
            }
            VStack(spacing: 0) {
                ForEach(Array(songs.dropFirst().enumerated()), id: \.element.id) { index, song in
                    Button { play(song) } label: { row(song, rank: index + 2) }
                        .buttonStyle(ListeningPressStyle())
                        .disabled(!song.isAvailable)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(label(song, rank: index + 2))
                        .accessibilityHint(song.isAvailable ? "Plays this song" : "")
                        .accessibilityIdentifier("listening-top-song-\(index + 2)")
                }
            }
        }
    }

    private func featured(_ song: RankedSong) -> some View {
        HStack(alignment: .bottom, spacing: AppSpacing.lg) {
            ManagedArtworkView(path: song.artworkPath, fallbackID: song.trackID, size: 136)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
                .shadow(color: .black.opacity(0.6), radius: 18, y: 10)
                .opacity(song.isAvailable ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 6) {
                ListeningRankNumber(rank: 1, size: 40)
                Text(song.title).font(.title3.weight(.bold)).foregroundStyle(AppColors.textPrimary).lineLimit(2)
                Text(song.artistName).font(.subheadline).foregroundStyle(AppColors.textSecondary).lineLimit(1)
                HStack(spacing: AppSpacing.sm) {
                    Text(ListeningFormat.duration(song.listenedMs)).font(.subheadline.weight(.semibold)).foregroundStyle(ListeningStyle.accent)
                    Text(ListeningFormat.plays(song.plays)).font(.caption).foregroundStyle(AppColors.textTertiary)
                }
                if !song.isAvailable { unavailableTag }
            }
            Spacer(minLength: 0)
        }
        .padding(AppSpacing.lg)
        .background(
            LinearGradient(colors: [ListeningStyle.accent.opacity(0.14), AppColors.backgroundPrimary.opacity(0)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.large))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.large).stroke(ListeningStyle.accent.opacity(0.12)))
    }

    private func row(_ song: RankedSong, rank: Int) -> some View {
        HStack(spacing: AppSpacing.md) {
            ListeningRankNumber(rank: rank)
            ManagedArtworkView(path: song.artworkPath, fallbackID: song.trackID, size: 46).opacity(song.isAvailable ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 4) {
                Text(song.title).font(.body.weight(.medium)).foregroundStyle(song.isAvailable ? AppColors.textPrimary : AppColors.textSecondary).lineLimit(1)
                HStack(spacing: 6) {
                    Text(song.artistName).lineLimit(1)
                    if !song.isAvailable { Text("· Unavailable") }
                }.font(.caption).foregroundStyle(AppColors.textSecondary)
                ListeningShareBar(fraction: fraction(song))
            }
            Text(ListeningFormat.duration(song.listenedMs)).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(AppColors.textSecondary)
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
    }

    private var unavailableTag: some View {
        Text("Unavailable").font(.caption2.weight(.semibold)).foregroundStyle(AppColors.warning)
            .padding(.horizontal, 8).padding(.vertical, 3).overlay(Capsule().stroke(AppColors.warning.opacity(0.5)))
    }

    private func fraction(_ song: RankedSong) -> Double {
        guard let top = songs.first?.listenedMs, top > 0 else { return 0 }
        return Double(song.listenedMs) / Double(top)
    }

    private func label(_ song: RankedSong, rank: Int) -> String {
        "Number \(rank), \(song.title) by \(song.artistName), \(ListeningFormat.spokenDuration(song.listenedMs)), \(ListeningFormat.plays(song.plays))" + (song.isAvailable ? "" : ", unavailable")
    }
}

/// Top Artists: circular artwork, large rank numbers and bars relative to the leader.
struct TopArtistsSection<Destination: View>: View {
    let artists: [RankedCollection]
    let destination: (RankedCollection) -> Destination

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            ListeningStyle.eyebrow("Top Artists")
            if let first = artists.first {
                NavigationLink { destination(first) } label: {
                    HStack(spacing: AppSpacing.lg) {
                        ManagedArtworkView(path: first.artworkPath, fallbackID: first.id, size: 104).clipShape(Circle())
                            .overlay(Circle().stroke(ListeningStyle.accent.opacity(0.6), lineWidth: 1.5).padding(-5))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Most listened-to artist").font(.caption.weight(.semibold)).foregroundStyle(ListeningStyle.accent)
                            Text(first.title).font(.title2.weight(.bold)).foregroundStyle(AppColors.textPrimary).lineLimit(2)
                            Text("\(ListeningFormat.duration(first.listenedMs)) · \(ListeningFormat.plays(first.plays))")
                                .font(.subheadline).foregroundStyle(AppColors.textSecondary)
                            Text(shareText(first)).font(.caption).foregroundStyle(AppColors.textTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, AppSpacing.sm).contentShape(Rectangle())
                }
                .buttonStyle(ListeningPressStyle())
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("listening-top-artist-1")
            }
            ForEach(Array(artists.dropFirst().enumerated()), id: \.element.id) { index, artist in
                NavigationLink { destination(artist) } label: {
                    HStack(spacing: AppSpacing.md) {
                        ListeningRankNumber(rank: index + 2, size: 28)
                        ManagedArtworkView(path: artist.artworkPath, fallbackID: artist.id, size: 44).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(artist.title).font(.body.weight(.medium)).foregroundStyle(AppColors.textPrimary).lineLimit(1)
                                Spacer()
                                Text(ListeningFormat.duration(artist.listenedMs)).font(.subheadline).monospacedDigit().foregroundStyle(AppColors.textSecondary)
                            }
                            ListeningShareBar(fraction: Double(artist.listenedMs) / Double(max(artists.first?.listenedMs ?? 1, 1)))
                        }
                    }
                    .frame(minHeight: 56).contentShape(Rectangle())
                }
                .buttonStyle(ListeningPressStyle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Number \(index + 2), \(artist.title), \(ListeningFormat.spokenDuration(artist.listenedMs))")
                .accessibilityIdentifier("listening-top-artist-\(index + 2)")
            }
        }
    }

    private func shareText(_ first: RankedCollection) -> String {
        let total = artists.reduce(Int64(0)) { $0 + $1.listenedMs }
        guard artists.count > 1, total > 0 else { return "Your top artist" }
        let share = Int((Double(first.listenedMs) / Double(total) * 100).rounded())
        return "\(share)% of your top-artist listening"
    }
}

/// Albums and playlists as artwork-first collections in a horizontal carousel. The artwork
/// slot is a single view so Phase 11.5 can drop in rotating mosaics.
struct TopCollectionsCarousel<Destination: View>: View {
    let title: String
    let items: [RankedCollection]
    let showsPlays: Bool
    let identifier: String
    let destination: (RankedCollection) -> Destination

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            ListeningStyle.eyebrow(title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: AppSpacing.lg) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        NavigationLink { destination(item) } label: { card(item, rank: index + 1) }
                            .buttonStyle(ListeningPressStyle())
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Number \(index + 1), \(item.title)\(item.subtitle.isEmpty ? "" : ", " + item.subtitle), \(ListeningFormat.spokenDuration(item.listenedMs))\(showsPlays ? ", " + ListeningFormat.plays(item.plays) : "")")
                            .accessibilityIdentifier("\(identifier)-\(index + 1)")
                    }
                }
                .padding(.horizontal, AppSpacing.lg)
            }
            .padding(.horizontal, -AppSpacing.lg)
        }
    }

    private func card(_ item: RankedCollection, rank: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                ManagedArtworkView(path: item.artworkPath, fallbackID: item.id, size: rank == 1 ? 168 : 136)
                Text("\(rank)").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(rank == 1 ? Color.black : AppColors.textPrimary)
                    .frame(width: 28, height: 28).background(Circle().fill(rank == 1 ? ListeningStyle.accent : Color.black.opacity(0.7)))
                    .padding(8)
            }
            Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(AppColors.textPrimary).lineLimit(1)
            if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption).foregroundStyle(AppColors.textSecondary).lineLimit(1) }
            Text(showsPlays ? "\(ListeningFormat.duration(item.listenedMs)) · \(ListeningFormat.plays(item.plays))" : ListeningFormat.duration(item.listenedMs))
                .font(.caption.weight(.medium)).foregroundStyle(ListeningStyle.accent)
        }
        .frame(width: rank == 1 ? 168 : 136, alignment: .leading)
    }
}

/// Short, subtle press feedback for rows and cards.
struct ListeningPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: Profile preview

/// The Profile page's Listening Activity entry: last 30 days at a glance and the way into
/// the full dashboard.
struct ListeningPreviewCard: View {
    @EnvironmentObject private var stats: ListeningStatsService
    private let range = ListeningRange.last30

    var body: some View {
        NavigationLink { ListeningDashboardView() } label: {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                HStack {
                    ListeningStyle.eyebrow("Last 30 Days")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(AppColors.textTertiary)
                }
                content
                Text("See Your Listening").font(.subheadline.weight(.semibold)).foregroundStyle(ListeningStyle.accent)
                    .frame(minHeight: 32)
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.backgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(ListeningPressStyle())
        .accessibilityIdentifier("profile-listening-activity")
        .onAppear { stats.load(range) }
    }

    @ViewBuilder private var content: some View {
        if let summary = stats.summary(range) {
            if summary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your listening story starts here.").font(.headline).foregroundStyle(AppColors.textPrimary)
                    Text("Accurate listening time is tracked from this update.").font(.caption).foregroundStyle(AppColors.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("profile-listening-empty")
            } else {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.lg) {
                    Text(ListeningFormat.duration(summary.listenedMs))
                        .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(AppColors.textPrimary).lineLimit(1).minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                        .accessibilityLabel("Listening time, \(ListeningFormat.spokenDuration(summary.listenedMs))")
                        .accessibilityIdentifier("profile-listening-time")
                    Text(ListeningFormat.plays(summary.qualifiedPlays)).font(.subheadline).foregroundStyle(AppColors.textSecondary)
                        .accessibilityIdentifier("profile-listening-plays")
                }
                if let top = summary.topSongs.first {
                    HStack(spacing: AppSpacing.md) {
                        ManagedArtworkView(path: top.artworkPath, fallbackID: top.trackID, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Most played").font(.caption2.weight(.semibold)).foregroundStyle(AppColors.textTertiary)
                            Text(top.title).font(.subheadline.weight(.medium)).foregroundStyle(AppColors.textPrimary).lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("profile-listening-top-song")
                }
            }
        } else if let failure = stats.failure(range) {
            Text(failure).font(.subheadline).foregroundStyle(AppColors.textSecondary)
        } else {
            RoundedRectangle(cornerRadius: AppRadius.small).fill(ListeningStyle.track).frame(width: 140, height: 34)
                .accessibilityLabel("Loading listening activity")
        }
    }
}
