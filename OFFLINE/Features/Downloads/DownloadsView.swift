import SwiftUI

struct DownloadsView: View {
    @ObservedObject var manager: DownloadManager
    @EnvironmentObject private var library: MusicLibraryService
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppSpacing.lg) {
                Text("Downloads").font(.title.bold())
                if let issue = manager.issue { Text(issue).foregroundStyle(AppColors.error) }
                if manager.jobs.isEmpty {
                    EmptyState(icon: "arrow.down.circle", title: "No downloads", message: "Choose Download Audio in Video Details to save a song.")
                }
                ForEach(manager.jobs) { job in
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        HStack {
                            YouTubeArtwork(url: job.thumbnail.flatMap(URL.init(string:))).frame(width: 60, height: 44)
                            VStack(alignment: .leading) {
                                Text(job.title ?? "Audio").font(.headline)
                                if let channel = job.channel { Text(channel).font(.caption) }
                            }
                        }
                        Text(manager.stateLabel(for: job)).accessibilityIdentifier("download-state-" + (job.sourceIdentifier ?? job.id))
                        if let message = job.errorMessage { Text(message).font(.caption) }
                        if job.state == .downloading {
                            if let expected = job.expected {
                                ProgressView(value: job.progress)
                                Text(job.progress.formatted(.percent.precision(.fractionLength(0))))
                                Text(bytes(job.received ?? 0) + " / " + bytes(expected))
                            } else { ProgressView(); Text(bytes(job.received ?? 0)) }
                            if let rate = manager.rates[job.id], Date().timeIntervalSince(job.dateModified) < 5 { Text(bytes(Int64(rate)) + "/s") }
                        }
                        HStack {
                            if job.state.stoppable { Button("Pause") { manager.pause(job) } }
                            if job.state.stoppable || job.state == .paused || job.state == .interrupted {
                                Button("Cancel") { manager.cancel(job) }
                            }
                            if [.failed, .cancelled, .interrupted, .paused].contains(job.state) {
                                Button(job.state == .paused ? "Resume" : "Retry") { manager.retry(job.id) }
                            }
                            if job.state.pending {
                                Button { manager.move(job, by: -1) } label: { Image(systemName: "arrow.up") }.accessibilityLabel("Move earlier").accessibilityIdentifier("earlier-" + (job.sourceIdentifier ?? job.id))
                                Button { manager.move(job, by: 1) } label: { Image(systemName: "arrow.down") }.accessibilityLabel("Move later")
                            }
                            if job.state == .completed, let id = job.trackID, library.track(id)?.availability == .available {
                                Button("Play") { Task { await library.play(id, ids: [id], kind: "library") } }.accessibilityIdentifier("play-download")
                            } else if job.state == .completed {
                                Button("Download again") { manager.retry(job.id, repair: true) }
                            }
                        }.buttonStyle(.bordered)
                    }.cardSurface()
                }
            }.padding(AppSpacing.lg)
        }.navigationBarHidden(true).screenBackground()
    }
    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}
