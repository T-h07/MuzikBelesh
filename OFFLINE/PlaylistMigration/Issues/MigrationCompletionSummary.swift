import Foundation

/// Where processing of one imported playlist stands, derived from authoritative state.
/// Processing finishing and the playlist being fully available offline are different
/// outcomes; matching completion and confirmed-download batches are neither.
enum MigrationCompletionOutcome: String, Codable, Sendable {
    /// Matching has not been started for this playlist.
    case notStarted
    /// Automatic work remains (matching, downloads, scheduled retries, cooldowns).
    case inProgress
    /// The user paused matching or downloads while work remains.
    case paused
    case cancelled
    /// Processing settled; some original occurrences are unresolved or skipped.
    case finishedWithIssues
    /// Every original occurrence has present, verified local audio.
    case fullyReady

    var settled: Bool { self == .finishedWithIssues || self == .fullyReady }

    var title: String {
        switch self {
        case .notStarted: "Matching Not Started"
        case .inProgress: "Processing"
        case .paused: "Paused"
        case .cancelled: "Migration Cancelled"
        case .finishedWithIssues: "Processing Finished — Needs Attention"
        case .fullyReady: "Playlist Ready Offline"
        }
    }
}

/// Counts refer to original imported occurrences only. Songs added to the destination
/// playlist later are ordinary local occurrences and never change these numbers.
/// Invariant: `playable + unresolved + skipped == total`.
struct MigrationCompletionSummary: Equatable, Sendable {
    var migrationID: UUID
    var playlistID: String
    var playlistName: String
    var total = 0
    var playable = 0
    var skipped = 0
    /// Unresolved subcounts.
    var needsReview = 0
    var failed = 0
    var waiting = 0
    var outcome: MigrationCompletionOutcome = .inProgress

    var unresolved: Int { needsReview + failed + waiting }
    /// Distinct occurrences that need the user (the "Migration Issues (N)" badge).
    var attention: Int { needsReview + failed }
    var accountedFor: Bool { playable + unresolved + skipped == total }
    var fullyReady: Bool { outcome == .fullyReady }

    /// Derives the outcome. `fullyReady` requires every occurrence to be playable: zero
    /// unresolved, zero skipped and no remaining work. A paused or waiting migration is
    /// never described as finished.
    static func make(migrationID: UUID, playlistID: String, playlistName: String, expected: Int,
                     dispositions: [MigrationOccurrenceDisposition], context: MigrationIssueContext) -> Self {
        var value = Self(migrationID: migrationID, playlistID: playlistID, playlistName: playlistName)
        value.total = dispositions.count
        for disposition in dispositions {
            switch disposition {
            case .playable: value.playable += 1
            case .skipped: value.skipped += 1
            case .needsReview: value.needsReview += 1
            case .failed: value.failed += 1
            case .waiting: value.waiting += 1
            }
        }
        let complete = value.total == expected && value.accountedFor
        if context.cancelled {
            value.outcome = .cancelled
        } else if complete && value.total > 0 && value.playable == value.total {
            value.outcome = .fullyReady
        } else if value.waiting > 0 {
            if context.matchingPaused || context.downloadsPaused { value.outcome = .paused }
            else if context.matchingIntent == nil && value.playable == 0 && value.attention == 0 { value.outcome = .notStarted }
            else { value.outcome = .inProgress }
        } else if value.total == 0 {
            // An empty source playlist has nothing to acquire.
            value.outcome = .fullyReady
        } else {
            value.outcome = .finishedWithIssues
        }
        return value
    }

    /// Stable fingerprint of the counts at a settled moment (notification revision).
    var revision: String { "\(outcome.rawValue):\(total):\(playable):\(needsReview):\(failed):\(skipped)" }

    /// "420 of 500 songs are playable offline. 65 need attention and 15 were skipped."
    var sentence: String {
        if outcome == .fullyReady {
            return total == 1 ? "The song is available offline." : "All \(total) songs are available offline."
        }
        var parts = ["\(playable) of \(total) \(total == 1 ? "song is" : "songs are") playable offline."]
        let attentionText = attention == 1 ? "1 needs attention" : "\(attention) need attention"
        let skippedText = skipped == 1 ? "1 was skipped" : "\(skipped) were skipped"
        if attention > 0 && skipped > 0 { parts.append(attentionText + " and " + skippedText + ".") }
        else if attention > 0 { parts.append(attentionText + ".") }
        else if skipped > 0 { parts.append(skippedText + ".") }
        if waiting > 0 { parts.append("\(waiting) still in progress.") }
        return parts.joined(separator: " ")
    }
}

/// The complete per-playlist report: one assessed row per original occurrence.
struct MigrationIssueReport: Equatable, Sendable {
    let summary: MigrationCompletionSummary
    let occurrences: [MigrationOccurrenceReport]
    let context: MigrationIssueContext

    func rows(_ filter: MigrationIssueFilter) -> [MigrationOccurrenceReport] { occurrences.filter { $0.matches(filter) } }
    func count(_ filter: MigrationIssueFilter) -> Int { occurrences.reduce(0) { $0 + ($1.matches(filter) ? 1 : 0) } }
    func occurrence(_ id: UUID) -> MigrationOccurrenceReport? { occurrences.first { $0.id == id } }
}
