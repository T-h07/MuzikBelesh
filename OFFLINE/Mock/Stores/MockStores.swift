import SwiftUI

final class MockMusicStore: ObservableObject {
    @Published var tracks = MockMusicCatalog.tracks
    @Published var playlists = MockMusicCatalog.playlists
    @Published var likedTrackIDs: Set<String> = ["track-neon", "track-midnight"]
    @Published var recentlyPlayedIDs: [String] = ["track-neon", "track-slow"]
    var albums: [MockAlbum] { MockMusicCatalog.albums }
    var artists: [MockArtist] { MockMusicCatalog.artists }
    func track(_ id: String) -> MockTrack? { tracks.first { $0.id == id } }
    func search(_ query: String) -> [MockTrack] { let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(); return q.isEmpty ? tracks : tracks.filter { $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q) || $0.album.lowercased().contains(q) } }
    func toggleLiked(_ id: String) { if likedTrackIDs.contains(id) { likedTrackIDs.remove(id) } else { likedTrackIDs.insert(id) } }
    func playRecorded(_ id: String) { recentlyPlayedIDs.removeAll { $0 == id }; recentlyPlayedIDs.insert(id, at: 0); recentlyPlayedIDs = Array(recentlyPlayedIDs.prefix(8)) }
    func createPlaylist(name: String) { playlists.append(MockPlaylist(id: "playlist-\(UUID().uuidString)", name: name, description: "Created in this session", trackIDs: [])) }
    func renamePlaylist(_ id: String, name: String) { guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }; playlists[index].name = name }
    func deletePlaylist(_ id: String) { playlists.removeAll { $0.id == id } }
    func add(_ trackID: String, to playlistID: String) { guard let index = playlists.firstIndex(where: { $0.id == playlistID }), !playlists[index].trackIDs.contains(trackID) else { return }; playlists[index].trackIDs.append(trackID) }
    func remove(_ trackID: String, from playlistID: String) { guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }; playlists[index].trackIDs.removeAll { $0 == trackID } }
    func editTrack(_ id: String, title: String, artist: String) { guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }; tracks[index].title = title; tracks[index].artist = artist }
}

final class MockPlaybackStore: ObservableObject {
    @Published var currentTrackID: String?
    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var queueIDs = MockMusicCatalog.tracks.map(\.id)
    @Published var shuffleEnabled = false
    @Published var repeatMode: RepeatMode = .off
    func select(_ id: String) { currentTrackID = id; position = 0; isPlaying = true }
    func togglePlayPause() { guard currentTrackID != nil else { return }; isPlaying.toggle() }
    func seek(_ value: Double, duration: Double) { position = min(max(value, 0), duration) }
    func next() { guard let id = currentTrackID, let index = queueIDs.firstIndex(of: id), !queueIDs.isEmpty else { return }; select(queueIDs[(index + 1) % queueIDs.count]) }
    func previous() { guard let id = currentTrackID, let index = queueIDs.firstIndex(of: id), !queueIDs.isEmpty else { return }; select(queueIDs[(index - 1 + queueIDs.count) % queueIDs.count]) }
    func addToQueue(_ id: String) { queueIDs.removeAll { $0 == id }; queueIDs.append(id) }
    func removeFromQueue(at offsets: IndexSet) { queueIDs.remove(atOffsets: offsets) }
    func cycleRepeat() { repeatMode = RepeatMode.allCases[(RepeatMode.allCases.firstIndex(of: repeatMode)! + 1) % RepeatMode.allCases.count] }
}

final class MockDownloadStore: ObservableObject {
    @Published var jobs: [MockDownloadJob] = MockMusicCatalog.videos.enumerated().map { MockDownloadJob(id: "job-\($0.offset)", video: $0.element, state: $0.offset == 0 ? .downloading : ($0.offset == 1 ? .completed : .queued), progress: $0.offset == 0 ? 0.42 : ($0.offset == 1 ? 1 : 0), errorMessage: nil) }
    func add(_ video: MockVideo) { guard !jobs.contains(where: { $0.video.id == video.id }) else { return }; jobs.insert(MockDownloadJob(id: "job-\(UUID().uuidString)", video: video, state: .resolving, progress: 0, errorMessage: nil), at: 0) }
    func advance(_ id: String) { guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }; jobs[index].progress = min(jobs[index].progress + 0.2, 1); jobs[index].state = jobs[index].progress >= 1 ? .completed : .downloading }
    func cancel(_ id: String) { guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }; jobs[index].state = .cancelled }
    func retry(_ id: String) { guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }; jobs[index].state = .resolving; jobs[index].errorMessage = nil }
}

final class MockSettingsStore: ObservableObject { @Published var audioQuality = "High"; @Published var wifiOnly = false; @Published var sleepTimer = "Off" }

