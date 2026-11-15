import XCTest
@testable import OFFLINE

final class SongMatchingPolicyTests: XCTestCase {
    private func source(_ title: String = "Song One (Studio)", artist: String? = "Artist A", duration: Int64? = 180000) -> PlaylistMigrationSourceTrack {
        .init(position: 0, title: title, primaryArtist: artist, album: "Album", durationMs: duration)
    }
    private func recording(_ title: String = "Song One (Studio)", artist: String? = "Artist A", duration: Int64? = 180000) -> SongRecording {
        .init(provider: "local", identity: "one", title: title, artist: artist, album: "Album", durationMs: duration, local: true)
    }
    private func outcome(_ source: PlaylistMigrationSourceTrack, _ recording: SongRecording) -> SongMatchDecision {
        MatchDecisionPolicy().decide([CandidateScoringEngine().score(source: source, candidate: recording)])
    }
    func testExactExplicitIdentityScoresOneHundred() {
        let decision = outcome(source(), recording())
        XCTAssertEqual(decision.outcome, .local)
        XCTAssertEqual(decision.ranked.first?.score, 100)
        XCTAssertEqual(decision.ranked.first?.gates, [])
    }
    func testUnlabelledVersionIsNotAssumedStudio() {
        let decision = outcome(source("Song One"), recording("Song One"))
        XCTAssertEqual(decision.outcome, .review)
        XCTAssertTrue(decision.ranked[0].gates.contains("Recording version is uncertain"))
        XCTAssertTrue(RecordingVersionClassifier.traits(title: "Live Forever (Official Audio)").contains(.unknown))
        XCTAssertNotEqual(outcome(source("Song (Studio Live)"), recording("Song (Studio Live)")).outcome, .local)
    }
    func testPrimaryArtistCannotBeOverriddenByScoreOrFeatures() {
        for artist in ["Artist B", "Artist B feat. Artist A", "", "Unknown Artist"] {
            XCTAssertNotEqual(outcome(source("Stay (Studio)"), recording("Stay (Studio)", artist: artist)).outcome, .local)
        }
    }
    func testAllVersionMismatchesBlockAndStructuredCombinationsSurvive() {
        for suffix in ["Live", "Remix", "Instrumental", "Acoustic", "Cover", "Karaoke", "Sped Up", "Slowed", "Nightcore", "Extended Mix", "Radio Edit", "Demo", "2024 Remaster"] {
            XCTAssertNotEqual(outcome(source(), recording("Song One (\(suffix))")).outcome, .local)
        }
        XCTAssertEqual(RecordingVersionClassifier.traits(title: "Song (Live Acoustic)"), [.live, .acoustic])
        XCTAssertEqual(RecordingVersionClassifier.traits(title: "Song (Extended Remix)"), [.extended, .remix])
        XCTAssertEqual(RecordingVersionClassifier.traits(title: "Song (2024 Remaster)"), [.remaster])
        XCTAssertEqual(RecordingVersionClassifier.traits(title: "Song", album: "Live Concert"), [.live])
    }
    func testCorrectRemixAndFeaturedArtistFormatting() {
        XCTAssertEqual(outcome(source("Song One (Remix)"), recording("Song One (Remix)")).outcome, .local)
        let decision = outcome(source(artist: "Artist A feat. Artist B & Artist C"), recording(artist: "Artist A ft. Artist C, Artist B"))
        XCTAssertEqual(decision.outcome, .local)
    }
    func testUnicodePunctuationAndOfficialLabels() {
        XCTAssertEqual(SongMetadataNormalizer.cleanTitle("  BOY   BETTER KNOW (Official Audio)"), "boy better know")
        XCTAssertEqual(SongMetadataNormalizer.words("Beyonce\u{301} — Don’t"), SongMetadataNormalizer.words("Beyoncé - Don't"))
        XCTAssertNotEqual(SongMetadataNormalizer.cleanTitle("Song (Live)"), SongMetadataNormalizer.cleanTitle("Song"))
        XCTAssertEqual(outcome(source("Song One (Studio)"), recording("SONG ONE [Studio] (Official Audio)")).outcome, .local)
    }
    func testDurationMissingZeroSevereAndProportionalMismatch() {
        for duration: Int64? in [nil, 0, 260000] {
            let decision = outcome(source(), recording(duration: duration))
            XCTAssertNotEqual(decision.outcome, .local)
            XCTAssertEqual(decision.ranked[0].evidence["durationScore"], "0.0")
        }
        XCTAssertNotEqual(outcome(source(duration: 2000), recording(duration: 3500)).outcome, .local)
        XCTAssertEqual(outcome(source(), recording(duration: 182000)).outcome, .local)
        XCTAssertNotEqual(outcome(source(duration: Int64.max), recording(duration: 1)).outcome, .local)
    }
    func testCommonWordMissingWordsAndWordOrderCannotAutoMatch() {
        for title in ["Song", "One Song (Studio)", "Song Two (Studio)", "One (Studio)"] {
            XCTAssertNotEqual(outcome(source(), recording(title)).outcome, .local)
        }
    }
    func testNearEqualCompetitorsAndOverflowRequireReview() {
        let score = CandidateScoringEngine().score(source: source(), candidate: recording())
        XCTAssertEqual(MatchDecisionPolicy().decide([score, score]).outcome, .review)
        XCTAssertEqual(MatchDecisionPolicy().decide([score], truncated: true).outcome, .review)
        let permissive = try! SongMatchingConfiguration(margin: 0)
        XCTAssertEqual(MatchDecisionPolicy(configuration: permissive).decide([score, score]).outcome, .review)
    }
    func testExternalProposalNeverMeansLocalAcceptanceAndChannelIsNotPerformer() {
        var remote = recording(); remote.local = false
        XCTAssertEqual(outcome(source(), remote).outcome, .recommended)
        remote.performerEstablished = false
        XCTAssertEqual(outcome(source(), remote).outcome, .review)
        remote.available = false
        XCTAssertTrue(outcome(source(), remote).ranked[0].gates.contains("Recording is unavailable"))
    }
    func testInvalidConfigurationAndLowThresholdCannotDisableGates() throws {
        for pair in [(90.0, 90.0), (101, 65), (90, -1), (.nan, 65)] {
            XCTAssertThrowsError(try SongMatchingConfiguration(high: pair.0, review: pair.1))
        }
        let config = try SongMatchingConfiguration(high: 1, review: 0, margin: 0)
        let score = CandidateScoringEngine(configuration: config).score(source: source(), candidate: recording(artist: "Artist B"))
        XCTAssertEqual(MatchDecisionPolicy(configuration: config).decide([score]).outcome, .review)
    }
    func testDeterministicScoresAndEvidenceDoNotMutateSource() {
        let input = source(), candidate = recording()
        let a = CandidateScoringEngine().score(source: input, candidate: candidate)
        let b = CandidateScoringEngine().score(source: input, candidate: candidate)
        XCTAssertEqual(a.score, b.score); XCTAssertEqual(a.evidence, b.evidence)
        XCTAssertEqual(input.title, "Song One (Studio)")
    }
}
