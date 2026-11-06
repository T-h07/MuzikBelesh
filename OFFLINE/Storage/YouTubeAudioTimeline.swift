import AVFoundation
import GRDB
import OSLog

/// Compare the movie header with the presentation times and frame count of decoded audio.
struct YouTubeAudioTimeline {
    let asset: Double
    let track: Double
    let fileFrames: Double
    let decoded: Double
    let presentationEnd: Double

    var indexedSeconds: Double? = nil

    static func agrees(_ a: Double, _ b: Double) -> Bool {
        a.isFinite && b.isFinite && a > 0 && b > 0 && abs(a - b) <= max(0.15, min(1, b * 0.005))
    }

    func correction(for reported: Double) -> Double? {
        if let indexedSeconds, abs(reported / indexedSeconds - 2) < 0.05, reported > indexedSeconds + 1 {
            return indexedSeconds
        }
        // Silence, gaps and edit lists can make a frame count shorter than a valid presentation.
        // Require contiguous decoded media starting near zero and a second local clock.
        guard Self.agrees(decoded, presentationEnd),
              [track, fileFrames, asset].contains(where: { Self.agrees($0, decoded) }),
              reported > decoded + 1, abs(reported / decoded - 2) < 0.05 else { return nil }
        return presentationEnd
    }

    static func inspect(_ url: URL, source: Double? = nil) async throws -> Self {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let movie = try await asset.load(.duration).seconds
        guard let audio = try await asset.loadTracks(withMediaType: .audio).first else { throw StorageError.unsupportedAudio }
        let range = try await audio.load(.timeRange)
        let file = try AVAudioFile(forReading: url)
        let frames = Double(file.length) / file.processingFormat.sampleRate
        let indexed = try FragmentedAACIndex.duration(of: url, sampleRate: file.fileFormat.sampleRate)
        if let indexed {
            // Two on-disk clocks agree: segment durations and AAC packet count. AVFoundation
            // can append the fragment duration to the populated movie header for this layout.
            Logger(subsystem: "com.th07.muzikbelesh", category: "AudioTimeline").info("source=\(source ?? -1) asset=\(movie) track=\(range.duration.seconds) indexed=\(indexed) fileFrames=\(file.length) processingHz=\(file.processingFormat.sampleRate) fileHz=\(file.fileFormat.sampleRate)")
            return Self(asset: movie, track: range.duration.seconds, fileFrames: frames, decoded: .nan, presentationEnd: .nan, indexedSeconds: indexed)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw StorageError.unsupportedAudio }
        reader.add(output)
        guard reader.startReading() else { throw StorageError.unsupportedAudio }
        var seconds = 0.0, end = 0.0
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  let rate = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate, rate > 0 else { throw StorageError.unsupportedAudio }
            let length = Double(CMSampleBufferGetNumSamples(buffer)) / rate
            seconds += length
            end = max(end, CMSampleBufferGetPresentationTimeStamp(buffer).seconds + length)
        }
        guard reader.status == .completed, seconds > 0 else { throw StorageError.unsupportedAudio }
        let frameSeconds = Double(file.length) / file.processingFormat.sampleRate
        let result = Self(asset: movie, track: range.duration.seconds, fileFrames: frameSeconds, decoded: seconds, presentationEnd: end)
        Logger(subsystem: "com.th07.muzikbelesh", category: "AudioTimeline").info("source=\(source ?? -1) asset=\(movie) track=\(result.track) fileFrames=\(file.length) processingHz=\(file.processingFormat.sampleRate) fileHz=\(file.fileFormat.sampleRate) decodedSeconds=\(seconds) presentationEnd=\(end)")
        return result
    }
}

extension StorageCoordinator {
    /// Restoration can run before the upgrade audit reaches the current track.
    func downloadPlaybackDuration(track: StoredTrack, url: URL) async -> Double? {
        guard let ms = track.durationMs, ms > 0 else { return nil }
        let downloaded = track.metadataSource == "youtube" ||
            (track.metadataSource == "local_edit" && (try? downloads.ownsFile(of: track)) == true)
        guard downloaded else { return nil }
        let stored = Double(ms) / 1000
        if let file = try? AVAudioFile(forReading: url),
           let index = try? FragmentedAACIndex.duration(of: url, sampleRate: file.fileFormat.sampleRate),
           abs(stored / index - 2) < 0.05 { return index }
        return stored
    }

    @discardableResult
    func repairYouTubeDurations(shouldContinue: @Sendable () async -> Bool = { true }) async throws -> Bool {
        let candidates = try await database.dbQueue.read { db in
            try StoredTrack.fetchAll(db, sql: """
                SELECT DISTINCT t.* FROM tracks t JOIN track_sources s ON s.trackID = t.id
                JOIN download_jobs j ON j.sourceIdentifier = s.sourceIdentifier AND j.trackID = t.id
                WHERE s.sourceType = 'youtube' AND j.sourceType = 'youtube' AND t.availability = 'available'
                AND (t.metadataSource = 'youtube' OR t.originalFilename = j.id || '.m4a')
                AND NOT EXISTS (SELECT 1 FROM settings WHERE key = 'durationAudit.1.' || t.id AND value = t.contentSHA256)
                """)
        }
        for track in candidates {
            try Task.checkCancellation()
            guard await shouldContinue() else { return false }
            guard let stored = track.durationMs, let url = try? paths.musicURL(relativePath: track.fileRelativePath),
                  let timeline = try? await YouTubeAudioTimeline.inspect(url) else { continue }
            let corrected = timeline.correction(for: Double(stored) / 1000)
            if corrected != nil, (try? audio.sha256(url: url)) != track.contentSHA256 { continue }
            try await database.dbQueue.write { db in
                guard let current = try StoredTrack.fetchOne(db, key: track.id), current.durationMs == stored,
                      current.contentSHA256 == track.contentSHA256, current.availability == .available else { return }
                if let corrected {
                    try db.execute(sql: "UPDATE tracks SET durationMs = ? WHERE id = ?", arguments: [Int64((corrected * 1000).rounded()), track.id])
                }
                try StoredSetting(key: "durationAudit.1." + track.id, value: track.contentSHA256, valueType: "string", dateModified: Date()).save(db)
            }
        }
        return true
    }
}
