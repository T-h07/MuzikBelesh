import Foundation

enum RepeatMode: String, CaseIterable, Codable { case off, all, one }

enum PlaybackStatus: Equatable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case interrupted
    case ended
    case failed(message: String)
}

struct AudioPlaybackState: Equatable {
    var currentTrackID: String?
    var status: PlaybackStatus = .idle
    var elapsedTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isSeeking = false
    var currentOutputRoute = "No audio route"
    var lastError: String?
    var canSeek: Bool { duration.isFinite && duration > 0 }
    var canSkipNext = false
    var canSkipPrevious = false
    var isPlaying: Bool { status == .playing }
}

enum AudioPlaybackError: LocalizedError, Equatable {
    case storageUnavailable
    case trackNotFound
    case missingFile
    case unsupportedAudio
    case playerFailed(String)

    var errorDescription: String? {
        switch self {
        case .storageUnavailable: return "Local music storage is unavailable."
        case .trackNotFound: return "That track is no longer in the library."
        case .missingFile: return "The audio file is missing from Muzik Belesh."
        case .unsupportedAudio: return "The local file is not a supported audio asset."
        case .playerFailed(let message): return message
        }
    }
}

struct PlaybackContext: Equatable {
    var trackIDs: [String]
    var currentIndex: Int?
    var nextID: String? { guard let currentIndex, currentIndex + 1 < trackIDs.count else { return nil }; return trackIDs[currentIndex + 1] }
    var previousID: String? { guard let currentIndex, currentIndex > 0 else { return nil }; return trackIDs[currentIndex - 1] }
    func settingCurrent(_ id: String) -> PlaybackContext { var copy = self; copy.currentIndex = trackIDs.firstIndex(of: id); return copy }
}
