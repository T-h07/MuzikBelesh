import Foundation

/// Phase 10.7 aggregate notifications, delivered through the same
/// `UNUserNotificationCenter` delegate and delivery contract as Phase 10.5
/// (`UserNotificationAcquisitionNotifier`). `.delivered` means iOS accepted the request,
/// not that the user saw it.
@MainActor protocol MigrationIssueNotifying: AnyObject {
    func deliverMigrationReport(identifier: String, title: String, body: String, playlistID: String,
                                opensIssues: Bool) async -> AcquisitionNotificationDelivery
    /// Called with the destination playlist when an attention notification is opened.
    var onOpenIssues: ((String) -> Void)? { get set }
}

/// One aggregate notification per migration and processing cycle — never one per song.
enum MigrationIssueNotificationContent {
    /// Stable per (migration, cycle): re-submitting after a crash replaces the pending
    /// request instead of adding a second one.
    static func identifier(_ event: MigrationReportEvent) -> String {
        switch event.kind {
        // Shared with the acquisition coordinator's full-playlist notification.
        case .fullyReady: "playlist-ready-" + event.migrationID.uuidString
        case .needsAttention: "migration-attention-\(event.migrationID.uuidString)-\(event.cycle)"
        }
    }

    static func title(_ kind: MigrationReportEvent.Kind) -> String {
        kind == .fullyReady ? "Playlist Ready Offline" : "Playlist Needs Attention"
    }

    /// Concise and never claims completion while songs remain unresolved; skipped songs
    /// are stated when present.
    static func body(_ summary: MigrationCompletionSummary) -> String {
        let name = "“\(summary.playlistName)”"
        if summary.fullyReady {
            return summary.total == 1 ? "The song in \(name) is available offline." : "All \(summary.total) songs in \(name) are available offline."
        }
        var text = "\(summary.playable) of \(summary.total) songs in \(name) are available offline."
        let attention = summary.attention
        if attention > 0 { text += attention == 1 ? " 1 still needs your review." : " \(attention) still need your review." }
        if summary.skipped > 0 { text += summary.skipped == 1 ? " 1 was skipped." : " \(summary.skipped) were skipped." }
        return text
    }
}
