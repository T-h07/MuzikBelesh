import Foundation

/// Immutable policy. Preferences can change thresholds, never bypass identity gates.
struct SongMatchingConfiguration: Sendable {
    let high: Double
    let review: Double
    let margin: Double
    let strongDurationMs: Double
    let acceptableDurationMs: Double
    let maximumDurationMs: Double
    let maximumDurationRatio: Double
    static let standard = try! Self()
    init(high: Double = 90, review: Double = 65, margin: Double = 12,
         strongDurationMs: Double = 2000, acceptableDurationMs: Double = 5000,
         maximumDurationMs: Double = 10000, maximumDurationRatio: Double = 0.05) throws {
        guard [high, review, margin, strongDurationMs, acceptableDurationMs, maximumDurationMs, maximumDurationRatio].allSatisfy(\.isFinite),
              0 <= review, review < high, high <= 100, (0...100).contains(margin),
              strongDurationMs > 0, acceptableDurationMs >= strongDurationMs,
              maximumDurationMs >= acceptableDurationMs, maximumDurationRatio > 0, maximumDurationRatio <= 0.1 else {
            throw SongMatchingError.invalidConfiguration
        }
        self.high = high; self.review = review; self.margin = margin
        self.strongDurationMs = strongDurationMs; self.acceptableDurationMs = acceptableDurationMs
        self.maximumDurationMs = maximumDurationMs; self.maximumDurationRatio = maximumDurationRatio
    }
}

enum SongMatchingError: Error { case invalidConfiguration, staleAttempt, busy }

enum RecordingVersionTrait: String, CaseIterable, Sendable {
    case studio, live, remix, instrumental, acoustic, cover, karaoke, spedUp, slowed, nightcore
    case extended, radioEdit, demo, remaster, unknown
}

enum SongMetadataNormalizer {
    static func words(_ value: String) -> String {
        let folded = String(value.prefix(1000)).precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "[’‘'`ˈ]", with: "", options: .regularExpression)
        return folded.replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    static func cleanTitle(_ value: String) -> String {
        // Remove presentation labels only. Version words and unknown qualifiers survive.
        let clean = value.replacingOccurrences(of: "(?i)\\b(official (audio|music video|video|lyric video)|lyrics video|lyric video)\\b", with: "", options: .regularExpression)
        return words(splitFeature(clean).0)
    }
    static func splitFeature(_ value: String) -> (String, [String]) {
        guard let range = value.range(of: "(?i)\\b(feat\\.?|ft\\.?|featuring)\\s+", options: .regularExpression) else { return (value, []) }
        let guests = String(value[range.upperBound...]).replacingOccurrences(of: "[()\\[\\]]", with: "", options: .regularExpression)
        return (String(value[..<range.lowerBound]), artists(guests))
    }
    static func artists(_ value: String) -> [String] {
        value.replacingOccurrences(of: "(?i)\\s+(and|x)\\s+|[,&;/]", with: "|", options: .regularExpression)
            .components(separatedBy: "|").map(words).filter { !$0.isEmpty }
    }
    static func artist(_ value: String?) -> (String, Set<String>) {
        let (primary, guests) = splitFeature(value ?? "")
        // Ambiguous joint primary credits remain whole; never pick the first performer.
        return (words(primary), Set(guests))
    }
}

enum RecordingVersionClassifier {
    static func traits(title: String, album: String? = nil, description: String? = nil) -> Set<RecordingVersionTrait> {
        let text = SongMetadataNormalizer.words([title, album ?? "", description ?? ""].joined(separator: " "))
        let patterns: [(RecordingVersionTrait, String)] = [
            (.studio, "studio|original mix|original version"), (.live, "live|concert"),
            (.remix, "remix|remixed"), (.instrumental, "instrumental"), (.acoustic, "acoustic|unplugged"),
            (.cover, "cover|tribute"), (.karaoke, "karaoke"), (.spedUp, "sped up|speed up"),
            (.slowed, "slowed|slowed down"), (.nightcore, "nightcore"), (.extended, "extended"),
            (.radioEdit, "radio edit|radio version"), (.demo, "demo"), (.remaster, "remaster|remastered")]
        var result = Set(patterns.compactMap { trait, pattern in
            text.range(of: "\\b(" + pattern + ")\\b", options: .regularExpression) == nil ? nil : trait
        })
        // A word in a song name (for example "Live Forever") is not a version
        // declaration. Retain the risk indicator but also mark identity unknown.
        let qualified = title.range(of: "[()\\[\\]]|\\s[-–—]\\s", options: .regularExpression) != nil
        let supporting = SongMetadataNormalizer.words((album ?? "") + " " + (description ?? ""))
        let supportingTrait = patterns.contains { supporting.range(of: "\\b(" + $0.1 + ")\\b", options: .regularExpression) != nil }
        if result.isEmpty || (!qualified && !supportingTrait) { result.insert(.unknown) }
        return result
    }
}

/// Provider-neutral metadata. Channel names never become verified performer credits.
struct SongRecording: Sendable, Equatable {
    let provider: String
    let identity: String
    let title: String
    let artist: String?
    var additionalArtists: [String] = []
    var album: String? = nil
    var durationMs: Int64? = nil
    var description: String? = nil
    var performerEstablished = true
    var available = true
    var local = false
}

struct SongMatchScore: Sendable {
    let recording: SongRecording
    let score: Double
    let gates: [String]
    let evidence: [String: String]
}

enum SongMatchOutcome: String, Sendable { case local, recommended, review, noMatch }
struct SongMatchDecision: Sendable {
    let outcome: SongMatchOutcome
    let ranked: [SongMatchScore]
    let explanation: String
    let margin: Double
}

struct CandidateScoringEngine: Sendable {
    static let algorithmVersion = "10.4.1"
    let configuration: SongMatchingConfiguration
    init(configuration: SongMatchingConfiguration = .standard) { self.configuration = configuration }

    func score(source: PlaylistMigrationSourceTrack, candidate: SongRecording) -> SongMatchScore {
        let title = SongMetadataNormalizer.cleanTitle(source.title)
        let otherTitle = SongMetadataNormalizer.cleanTitle(candidate.title)
        let (artist, features) = SongMetadataNormalizer.artist(source.primaryArtist)
        let (otherArtist, otherFeatures) = SongMetadataNormalizer.artist(candidate.artist)
        let sourceGuests = features.union(source.additionalArtists.flatMap(SongMetadataNormalizer.artists)).union(SongMetadataNormalizer.splitFeature(source.title).1)
        let candidateGuests = otherFeatures.union(candidate.additionalArtists.flatMap(SongMetadataNormalizer.artists)).union(SongMetadataNormalizer.splitFeature(candidate.title).1)
        let exactTitle = !title.isEmpty && title == otherTitle
        let artistAgrees = !artist.isEmpty && artist != "unknown artist" && artist == otherArtist && candidate.performerEstablished
        let titlePoints = 35 * Self.similarity(title, otherTitle)
        let artistPoints: Double = artistAgrees ? 30 : 0
        let featurePoints: Double = sourceGuests == candidateGuests ? 10 : 0
        var gates: [String] = []
        if !exactTitle { gates.append("Title identity is not exact") }
        if !artistAgrees { gates.append("Primary artist is conflicting or unproven") }
        if sourceGuests != candidateGuests { gates.append("Featured artist credits differ") }
        if !candidate.available { gates.append("Recording is unavailable") }

        var durationPoints = 0.0
        var difference: Double?
        if let a = source.durationMs, let b = candidate.durationMs, a > 0, b > 0 {
            let delta = abs(Double(a) - Double(b)); difference = delta
            let ratio = delta / Double(min(a, b))
            if delta > configuration.maximumDurationMs || ratio > configuration.maximumDurationRatio {
                gates.append("Duration mismatch")
            } else if delta <= configuration.strongDurationMs { durationPoints = 10 }
            else if delta <= configuration.acceptableDurationMs { durationPoints = 7 }
            else { durationPoints = 2; gates.append("Duration needs review") }
        } else { gates.append("Duration is unknown") }

        let aVersion = RecordingVersionClassifier.traits(title: source.title, album: source.album)
        let bVersion = RecordingVersionClassifier.traits(title: candidate.title, album: candidate.album, description: candidate.description)
        // Absence of a qualifier is never proof of studio identity. Even matching
        // unlabelled titles, albums and durations require review.
        let knownVersion = !aVersion.contains(.unknown) && !bVersion.contains(.unknown)
        let versionAgrees = knownVersion && aVersion == bVersion
        if !versionAgrees {
            gates.append(aVersion == bVersion || aVersion == [.unknown] || bVersion == [.unknown]
                         ? "Recording version is uncertain" : "Recording versions conflict")
        }
        let album = SongMetadataNormalizer.words(source.album ?? "")
        let albumAgrees = !album.isEmpty && album == SongMetadataNormalizer.words(candidate.album ?? "")
        let versionPoints: Double = versionAgrees ? 10 : 0
        let albumPoints: Double = albumAgrees ? 5 : 0
        let score = min(100, max(0, titlePoints + artistPoints + featurePoints + durationPoints + versionPoints + albumPoints))
        let classification = score >= configuration.high ? "High confidence" : score >= configuration.review ? "Review required" : "Low confidence"
        let evidence = [
            "matchingAlgorithmVersion": Self.algorithmVersion,
            "sourceTitleNormalized": title, "candidateTitleNormalized": otherTitle,
            "primaryArtistAgreement": artistAgrees ? "Established" : "Unproven or conflicting",
            "featuredArtistAgreement": sourceGuests == candidateGuests ? "Compatible credits" : "Different credits",
            "titleScore": String(titlePoints), "artistScore": String(artistPoints),
            "featuredArtistScore": String(featurePoints), "durationScore": String(durationPoints),
            "versionScore": String(versionPoints), "albumScore": String(albumPoints),
            "durationDifferenceMs": difference.map { String(Int64($0)) } ?? "Unknown",
            "sourceVersion": aVersion.map(\.rawValue).sorted().joined(separator: ", "),
            "candidateVersion": bVersion.map(\.rawValue).sorted().joined(separator: ", "),
            "versionCompatibility": versionAgrees ? "Compatible explicit traits" : "Not established",
            "confidenceScore": String(score), "confidenceClassification": classification,
            "hardGateFailures": gates.joined(separator: "; "),
            "providerIdentity": candidate.provider + ":" + candidate.identity]
        return SongMatchScore(recording: candidate, score: score, gates: gates, evidence: evidence)
    }

    private static func similarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let left = Set(a.split(separator: " ")), right = Set(b.split(separator: " "))
        let tokens = Double(left.intersection(right).count) / Double(left.union(right).count)
        let x = Array(a.prefix(300)), y = Array(b.prefix(300))
        var row = Array(0...y.count)
        for (i, char) in x.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: y.count)
            for j in y.indices { next[j + 1] = min(next[j] + 1, row[j + 1] + 1, row[j] + (char == y[j] ? 0 : 1)) }
            row = next
        }
        let edit = 1 - Double(row[y.count]) / Double(max(x.count, y.count))
        return min(0.95, 0.6 * tokens + 0.4 * edit)
    }
}

struct MatchDecisionPolicy: Sendable {
    let configuration: SongMatchingConfiguration
    init(configuration: SongMatchingConfiguration = .standard) { self.configuration = configuration }
    func decide(_ scores: [SongMatchScore], truncated: Bool = false) -> SongMatchDecision {
        let ranked = scores.sorted { $0.score == $1.score ? ($0.recording.provider + $0.recording.identity) < ($1.recording.provider + $1.recording.identity) : $0.score > $1.score }
        guard let top = ranked.first else { return .init(outcome: .noMatch, ranked: [], explanation: "No suitable recording found. Retry is available.", margin: 0) }
        let margin = top.score - (ranked.dropFirst().first?.score ?? 0)
        let outcome: SongMatchOutcome
        let reason: String
        if truncated { outcome = .review; reason = "Candidate limit reached; uniqueness cannot be established." }
        else if top.score < configuration.review { outcome = .noMatch; reason = "Candidates have insufficient supporting evidence." }
        else if !top.gates.isEmpty { outcome = .review; reason = top.gates.joined(separator: "; ") }
        else if margin < configuration.margin { outcome = .review; reason = "Multiple near-equal candidates require review." }
        else if top.score < configuration.high { outcome = .review; reason = "Confidence is below the automatic threshold." }
        else { outcome = top.recording.local ? .local : .recommended; reason = top.recording.local ? "Unique identity; managed audio verification required before acceptance." : "Recommended external proposal. Acceptance and acquisition remain pending." }
        return .init(outcome: outcome, ranked: ranked, explanation: reason, margin: margin)
    }
}
