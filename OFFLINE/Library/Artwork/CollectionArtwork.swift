import Foundation

// Phase 11.5 dynamic collection artwork: the value types and the pure, deterministic parts
// (candidate preparation, mosaic selection and effective-artwork resolution). Nothing here
// touches the filesystem, the database, the network or playback.

/// What kind of multi-song collection an artwork belongs to. `playlist`, `album` and `artist`
/// are persisted in `collection_artwork_preferences.collectionKind`.
enum CollectionArtworkKind: String, CaseIterable, Codable, Sendable {
    case playlist, album, artist
    /// Virtual groups without an owner record (Unassigned Songs). They follow the app default.
    case unassigned

    var hasPersistentPreference: Bool { self != .unassigned }
    /// Only playlists and albums have a user-chosen cover (`artworkRelativePath` on their record).
    var supportsCustomCover: Bool { self == .playlist || self == .album }
    /// The owner table, for preference ownership checks.
    var ownerTable: String? {
        switch self {
        case .playlist: return "playlists"
        case .album: return "albums"
        case .artist: return "artists"
        case .unassigned: return nil
        }
    }
}

struct CollectionArtworkIdentity: Hashable, Sendable {
    let kind: CollectionArtworkKind
    let id: String
    init(kind: CollectionArtworkKind, id: String) { self.kind = kind; self.id = id }

    static func playlist(_ id: String) -> Self { Self(kind: .playlist, id: id) }
    static func artist(_ id: String) -> Self { Self(kind: .artist, id: id) }
    /// Album groups include the virtual Unassigned Songs group.
    static func album(_ groupID: String) -> Self {
        Self(kind: groupID == LibrarySnapshot.unassignedAlbumID ? .unassigned : .album, id: groupID)
    }
}

/// A per-collection choice. `appDefault` is the absence of a stored row.
enum CollectionArtworkMode: String, CaseIterable, Identifiable, Sendable {
    case appDefault
    case automatic
    case staticArtwork = "static"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appDefault: return "Use App Default"
        case .automatic: return "Automatic Mosaic"
        case .staticArtwork: return "Static Artwork"
        }
    }
}

/// The locally available artwork of one collection, prepared off the main actor.
struct CollectionArtworkEntry: Equatable, Sendable {
    /// The record's own cover (playlist/album user choice; an artist cover if one was ever stored).
    var customPath: String?
    /// Distinct managed artwork paths of the collection's songs, sorted by path so that
    /// reordering the same songs never changes a mosaic.
    var candidates: [String]
    /// The first song cover in collection order: the pre-11.5 single-cover fallback.
    var firstPath: String?

    static let empty = CollectionArtworkEntry(customPath: nil, candidates: [], firstPath: nil)
}

/// Four quadrants, top-left, top-right, bottom-left, bottom-right. `nil` is a neutral tile.
struct CollectionMosaicSelection: Hashable, Sendable {
    static let slotCount = 4
    let tiles: [String?]
    init(tiles: [String?]) {
        precondition(tiles.count == Self.slotCount, "A mosaic has exactly four tiles")
        self.tiles = tiles
    }
    var coverCount: Int { tiles.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }
    var key: String { tiles.map { $0 ?? "-" }.joined(separator: "|") }
}

/// What a collection shows, in the strict precedence order of Phase 11.5.
enum CollectionArtworkPresentation: Hashable, Sendable {
    /// 1. A valid user-chosen cover. Never replaced by a mosaic.
    case custom(String)
    /// 2. An automatic 2×2 mosaic.
    case mosaic(CollectionMosaicSelection)
    /// 3. The legacy single song cover (mosaics disabled for this collection).
    case single(String)
    /// 4. The generic collection artwork.
    case placeholder

    /// Image paths in drawing order (one for a single image, four slots for a mosaic).
    var slots: [String?] {
        switch self {
        case .custom(let path), .single(let path): return [path]
        case .mosaic(let selection): return selection.tiles
        case .placeholder: return []
        }
    }
    var key: String {
        switch self {
        case .custom(let path): return "custom:" + path
        case .mosaic(let selection): return "mosaic:" + selection.key
        case .single(let path): return "single:" + path
        case .placeholder: return "placeholder"
        }
    }
}

enum CollectionArtworkSelector {
    /// Managed artwork is stored flat inside the Artwork directory. Anything else (nested,
    /// absolute, hidden or traversing paths) is never read. `AppStoragePaths.artworkURL`
    /// additionally resolves symlinks before any file access.
    static func isSafeManagedPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 255, !path.hasPrefix(".") else { return false }
        return !path.contains("/") && !path.contains("\\") && !path.contains("..") && !path.contains("\0")
    }

    /// Distinct, safe candidate paths in a stable (sorted) order. Repeated occurrences and songs
    /// sharing one cover file count once.
    static func candidates<S: Sequence>(_ paths: S, excluding unusable: Set<String> = []) -> [String] where S.Element == String? {
        var seen = Set<String>()
        for case let path? in paths where isSafeManagedPath(path) && !unusable.contains(path) { seen.insert(path) }
        return seen.sorted()
    }

    /// Stable 64-bit FNV-1a, so selections are identical on every launch and device.
    static func seed(_ identity: CollectionArtworkIdentity) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(identity.kind.rawValue):\(identity.id)".utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return hash
    }

    /// The rotation epoch for a moment: every collection advances together, once per interval.
    static func epoch(at date: Date, interval: TimeInterval) -> Int {
        guard interval > 0, date.timeIntervalSince1970.isFinite else { return 0 }
        return Int((date.timeIntervalSince1970 / interval).rounded(.down))
    }

    /// Selects up to four covers. O(1) apart from reading four array elements.
    ///
    /// - 1–3 covers keep fixed cells (one: top-left; two: diagonal; three: all but bottom-right)
    ///   and neutral tiles elsewhere; nothing moves between rotations.
    /// - Exactly four covers are all shown in a fixed order; they are not reshuffled for motion.
    /// - More than four: the candidates are read through a seeded affine permutation in windows
    ///   of four, one window per epoch. Each pass over the candidates ("cycle") uses a new
    ///   permutation, so small collections also vary. Every cover appears within two passes, and
    ///   a selection never repeats the previous epoch's set of covers.
    static func select(_ candidates: [String], identity: CollectionArtworkIdentity, epoch: Int) -> CollectionMosaicSelection? {
        let count = candidates.count
        switch count {
        case 0: return nil
        case 1: return CollectionMosaicSelection(tiles: [candidates[0], nil, nil, nil])
        case 2: return CollectionMosaicSelection(tiles: [candidates[0], nil, nil, candidates[1]])
        case 3: return CollectionMosaicSelection(tiles: [candidates[0], candidates[1], candidates[2], nil])
        case 4: return CollectionMosaicSelection(tiles: candidates.map { Optional($0) })
        default:
            let indices = windowIndices(count: count, seed: seed(identity), epoch: epoch)
            return CollectionMosaicSelection(tiles: indices.map { Optional(candidates[$0]) })
        }
    }

    /// How many earlier epochs are replayed to keep consecutive selections distinct.
    static let lookback = 6

    /// Four distinct indices for `epoch` (`count > 4`). Deterministic: depends only on the count,
    /// the collection seed and the epoch. Replays a few earlier epochs so that when a new cycle's
    /// first window happens to equal the previous selection, it is shifted to a different one.
    static func windowIndices(count: Int, seed: UInt64, epoch: Int) -> [Int] {
        precondition(count > CollectionMosaicSelection.slotCount)
        var selected = window(count: count, seed: seed, epoch: epoch &- lookback, shift: 0)
        for step in stride(from: epoch &- lookback &+ 1, through: epoch, by: 1) {
            var candidate = window(count: count, seed: seed, epoch: step, shift: 0)
            if Set(candidate) == Set(selected) {
                for shift in 1..<count {
                    candidate = window(count: count, seed: seed, epoch: step, shift: shift)
                    if Set(candidate) != Set(selected) { break }
                }
            }
            selected = candidate
        }
        return selected
    }

    static func window(count: Int, seed: UInt64, epoch: Int, shift: Int) -> [Int] {
        let position = 4 &* epoch
        let cycle = floorDivision(position, count)
        let start = positiveModulo(position, count)
        let permutation = AffinePermutation(count: count, seed: mix(seed ^ (UInt64(bitPattern: Int64(cycle)) &* 0x9e37_79b9_7f4a_7c15)))
        return (0..<4).map { permutation.index((start + shift + $0) % count) }
    }

    /// SplitMix64 finalizer: decorrelates the per-cycle permutations.
    static func mix(_ value: UInt64) -> UInt64 {
        var x = value &+ 0x9e37_79b9_7f4a_7c15
        x = (x ^ (x >> 30)) &* 0xbf58_476d_1ce4_e5b9
        x = (x ^ (x >> 27)) &* 0x94d0_49bb_1331_11eb
        return x ^ (x >> 31)
    }

    static func floorDivision(_ value: Int, _ divisor: Int) -> Int {
        let quotient = value / divisor
        return (value % divisor != 0 && (value < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }

    /// The effective artwork of a collection. `unusable` holds paths that failed to load (missing
    /// or undecodable files); a failed custom cover falls through to the automatic artwork.
    static func presentation(entry: CollectionArtworkEntry?, mosaicEnabled: Bool, identity: CollectionArtworkIdentity,
                             epoch: Int, unusable: Set<String> = []) -> CollectionArtworkPresentation {
        guard let entry else { return .placeholder }
        if let custom = entry.customPath, isSafeManagedPath(custom), !unusable.contains(custom) { return .custom(custom) }
        if mosaicEnabled, let selection = select(entry.candidates, identity: identity, epoch: epoch) { return .mosaic(selection) }
        if let first = entry.firstPath, !unusable.contains(first) { return .single(first) }
        if let first = entry.candidates.first { return .single(first) }
        return .placeholder
    }

    static func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
        let remainder = value % modulus
        return remainder < 0 ? remainder + modulus : remainder
    }
}

/// `i → (a·i + b) mod n` with `gcd(a, n) = 1`: a bijection on `0..<n` without allocation.
struct AffinePermutation: Sendable {
    let count: Int
    let multiplier: Int
    let offset: Int

    init(count: Int, seed: UInt64) {
        precondition(count > 0)
        self.count = count
        guard count > 2 else { multiplier = 1; offset = 0; return }
        var candidate = 2 + Int(seed % UInt64(count - 2))
        // Terminates: 1 is coprime with every n, and the walk reaches it within n steps.
        while Self.gcd(candidate, count) != 1 { candidate = candidate + 1 >= count ? 1 : candidate + 1 }
        multiplier = candidate
        offset = Int((seed >> 32) % UInt64(count))
    }

    func index(_ position: Int) -> Int {
        let product = multiplier.multipliedReportingOverflow(by: position)
        let value = product.overflow ? Int((Int64(multiplier % count) * Int64(position % count)) % Int64(count)) : product.partialValue % count
        return (value + offset) % count
    }

    static func gcd(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (abs(a), abs(b))
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }
}

/// Prepares every collection's candidates from one library snapshot. Pure and `Sendable`, so
/// the service runs it on a background task; rows never query GRDB or scan the library.
enum CollectionArtworkIndexBuilder {
    static func build(snapshot: LibrarySnapshot, artistGroups: [LibraryGroup], albumGroups: [LibraryGroup],
                      unusable: Set<String> = []) -> [CollectionArtworkIdentity: CollectionArtworkEntry] {
        var tracks: [String: StoredTrack] = [:]
        tracks.reserveCapacity(snapshot.tracks.count)
        for track in snapshot.tracks { tracks[track.id] = track }
        func entry(custom: String?, trackIDs: [String]) -> CollectionArtworkEntry {
            let paths = trackIDs.map { tracks[$0]?.artworkRelativePath }
            let first = paths.lazy.compactMap { $0 }.first { CollectionArtworkSelector.isSafeManagedPath($0) && !unusable.contains($0) }
            return CollectionArtworkEntry(customPath: custom, candidates: CollectionArtworkSelector.candidates(paths, excluding: unusable), firstPath: first)
        }
        var result: [CollectionArtworkIdentity: CollectionArtworkEntry] = [:]

        // Playlists: ordinary memberships, or (Spotify-migrated and Muzik Belesh imported)
        // verified local recordings of migration entries followed by manual occurrences.
        let memberships = Dictionary(grouping: snapshot.memberships, by: \.playlistID)
        let occurrences = Dictionary(grouping: snapshot.localOccurrences, by: \.playlistID)
        let entries = Dictionary(grouping: snapshot.migrationEntries, by: \.migrationID)
        var sessions: [String: PlaylistMigrationSession] = [:]
        for session in snapshot.migrationSessions {
            if let destination = session.destinationPlaylistID, sessions[destination] == nil { sessions[destination] = session }
        }
        for playlist in snapshot.playlists {
            let ids: [String]
            if let session = sessions[playlist.id] {
                let imported = (entries[session.id] ?? []).filter { $0.status == .ready }.sorted { $0.position < $1.position }.compactMap(\.localTrackID)
                ids = imported + (occurrences[playlist.id] ?? []).sorted { $0.position < $1.position }.map(\.trackID)
            } else {
                ids = (memberships[playlist.id] ?? []).sorted { $0.position < $1.position }.map(\.trackID)
            }
            result[.playlist(playlist.id)] = entry(custom: playlist.artworkRelativePath, trackIDs: ids)
        }

        // Albums by persistent `albumID` (the groups already follow it); never by similar names.
        let albumCovers = Dictionary(uniqueKeysWithValues: snapshot.albums.map { ($0.id, $0.artworkRelativePath) })
        for group in albumGroups {
            let identity = CollectionArtworkIdentity.album(group.id)
            result[identity] = entry(custom: identity.kind == .album ? albumCovers[group.id] ?? nil : nil, trackIDs: group.trackIDs)
        }

        // Artists: performer and album-artist associations from the library groups. The group's
        // `artworkRelativePath` falls back to the first song cover, so only the artist record's
        // own stored cover counts as an explicit choice.
        let artistCovers = Dictionary(uniqueKeysWithValues: snapshot.artists.map { ($0.id, $0.artworkRelativePath) })
        for group in artistGroups {
            result[.artist(group.id)] = entry(custom: artistCovers[group.id] ?? nil, trackIDs: group.trackIDs)
        }
        return result
    }

    /// Every artwork path an index can display (for cache invalidation of removed artwork).
    static func referencedPaths(_ index: [CollectionArtworkIdentity: CollectionArtworkEntry]) -> Set<String> {
        var paths = Set<String>()
        for entry in index.values {
            if let custom = entry.customPath { paths.insert(custom) }
            paths.formUnion(entry.candidates)
        }
        return paths
    }
}
