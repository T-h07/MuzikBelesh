import Foundation

struct ResolvedAudioAsset {
    let track: StoredTrack
    let url: URL
}

struct LocalAudioAssetResolver {
    let storage: StorageCoordinator?

    func resolve(trackID: String) throws -> ResolvedAudioAsset {
        guard let storage else { throw AudioPlaybackError.storageUnavailable }
        guard let track = try storage.tracks.find(id: trackID) else { throw AudioPlaybackError.trackNotFound }
        guard track.availability == .available else { throw AudioPlaybackError.missingFile }
        guard SupportedAudioFormat.isSupported(URL(fileURLWithPath: track.fileRelativePath)) else { throw AudioPlaybackError.unsupportedAudio }
        let url = try storage.paths.musicURL(relativePath: track.fileRelativePath)
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw AudioPlaybackError.missingFile }
        return ResolvedAudioAsset(track: track, url: url)
    }
}
