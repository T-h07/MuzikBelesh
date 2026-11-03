import Foundation

struct MockTrack: Identifiable, Equatable { let id: String; var title: String; var artist: String; var album: String; var artwork: String; var duration: TimeInterval; var genre: String }
struct MockAlbum: Identifiable, Equatable { let id: String; let title: String; let artist: String; let artwork: String; let trackIDs: [String] }
struct MockArtist: Identifiable, Equatable { let id: String; let name: String; let artwork: String; let trackIDs: [String] }
struct MockPlaylist: Identifiable, Equatable { let id: String; var name: String; var description: String; var trackIDs: [String] }
struct MockVideo: Identifiable, Equatable { let id: String; let title: String; let channel: String; let duration: String; let artwork: String; let videoID: String }
enum MockDownloadState: String, CaseIterable { case queued, resolving, downloading, paused, waitingForWiFi, failed, completed, cancelled }
struct MockDownloadJob: Identifiable, Equatable { let id: String; let video: MockVideo; var state: MockDownloadState; var progress: Double; var errorMessage: String? }
enum RepeatMode: String, CaseIterable, Codable { case off, all, one }

enum MockMusicCatalog {
    static let tracks: [MockTrack] = [
        MockTrack(id: "track-neon", title: "Neon Afterglow", artist: "Luna Vale", album: "City Lights", artwork: "city-lights", duration: 214, genre: "Electronic"),
        MockTrack(id: "track-slow", title: "Slow Motion", artist: "The Northline", album: "Open Roads", artwork: "open-roads", duration: 192, genre: "Indie"),
        MockTrack(id: "track-midnight", title: "Midnight Radio", artist: "Mira Sol", album: "After Hours", artwork: "after-hours", duration: 248, genre: "Pop"),
        MockTrack(id: "track-summer", title: "Summer Rain", artist: "Juniper", album: "Soft Weather", artwork: "soft-weather", duration: 181, genre: "Acoustic"),
        MockTrack(id: "track-static", title: "Static Hearts", artist: "Luna Vale", album: "City Lights", artwork: "city-lights", duration: 227, genre: "Electronic"),
        MockTrack(id: "track-golden", title: "Golden Hour", artist: "Mira Sol", album: "After Hours", artwork: "after-hours", duration: 205, genre: "Pop")
    ]
    static let albums = [MockAlbum(id: "album-city", title: "City Lights", artist: "Luna Vale", artwork: "city-lights", trackIDs: ["track-neon", "track-static"]), MockAlbum(id: "album-roads", title: "Open Roads", artist: "The Northline", artwork: "open-roads", trackIDs: ["track-slow"]), MockAlbum(id: "album-hours", title: "After Hours", artist: "Mira Sol", artwork: "after-hours", trackIDs: ["track-midnight", "track-golden"])]
    static let artists = [MockArtist(id: "artist-luna", name: "Luna Vale", artwork: "city-lights", trackIDs: ["track-neon", "track-static"]), MockArtist(id: "artist-mira", name: "Mira Sol", artwork: "after-hours", trackIDs: ["track-midnight", "track-golden"]), MockArtist(id: "artist-northline", name: "The Northline", artwork: "open-roads", trackIDs: ["track-slow"])]
    static let playlists = [MockPlaylist(id: "playlist-favorites", name: "Liked Songs", description: "Your favorite tracks", trackIDs: ["track-neon", "track-midnight"]), MockPlaylist(id: "playlist-drive", name: "Night Drive", description: "For the long way home", trackIDs: ["track-static", "track-slow", "track-golden"])]
    static let videos = [MockVideo(id: "video-neko", title: "NEKO - N’FRONT", channel: "NEKO", duration: "3:42", artwork: "video-neko", videoID: "dQw4w9WgXcQ"), MockVideo(id: "video-gangnam", title: "PSY - GANGNAM STYLE", channel: "officialpsy", duration: "4:13", artwork: "video-gangnam", videoID: "9bZkp7q19f0"), MockVideo(id: "video-night", title: "Late Night Mix — City Pop", channel: "Muzik Belesh", duration: "12:08", artwork: "video-night", videoID: "QdBZY2fkU-0")]
}

