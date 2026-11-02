import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var container: AppContainer
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: AppSpacing.xl) { Text("Downloads").font(.system(size: 28, weight: .bold)).foregroundStyle(AppColors.textPrimary); Text("Mock download activity").font(.subheadline).foregroundStyle(AppColors.textSecondary); if container.downloads.jobs.isEmpty { EmptyState(icon: "arrow.down.circle", title: "No downloads", message: "Videos added from Search will appear here.") } else { ForEach(container.downloads.jobs) { job in ProgressRow(job: job).contextMenu { Button { container.downloads.advance(job.id) } label: { Label("Simulate Progress", systemImage: "forward.fill") }; Button { container.downloads.cancel(job.id) } label: { Label("Cancel", systemImage: "xmark") }; Button { container.downloads.retry(job.id) } label: { Label("Retry", systemImage: "arrow.clockwise") } } } } }.padding(.horizontal, AppSpacing.xl).padding(.top, AppSpacing.lg).padding(.bottom, 100) }.navigationBarHidden(true).screenBackground() }
}

