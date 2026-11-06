import Foundation

actor YouTubeSearchService: YouTubeSearchProvider {
    private struct Key: Hashable { let query: String; let token: String? }
    private struct Entry { let page: YouTubeSearchPage; let expires: Date; var accessed: Date }
    private let provider: any YouTubeSearchProvider
    private let now: @Sendable () -> Date
    private let lifetime: TimeInterval
    private let capacity: Int
    private var cache: [Key: Entry] = [:]
    private var generation = 0
    init(provider: any YouTubeSearchProvider, lifetime: TimeInterval = 180, capacity: Int = 20, now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider; self.lifetime = lifetime; self.capacity = max(1, capacity); self.now = now
    }
    nonisolated static func normalize(_ query: String) -> String { String(query.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(500)) }
    func invalidate() { generation += 1; cache.removeAll() }
    func search(query: String, continuationToken: String?) async throws -> YouTubeSearchPage {
        let query = Self.normalize(query)
        guard !query.isEmpty else { return YouTubeSearchPage(videos: [], continuationToken: nil) }
        try Task.checkCancellation()
        let key = Key(query: query, token: continuationToken), date = now(), revision = generation
        cache = cache.filter { $0.value.expires > date }
        if var hit = cache[key] { hit.accessed = date; cache[key] = hit; return hit.page }
        let page = try await provider.search(query: query, continuationToken: continuationToken)
        try Task.checkCancellation()
        var ids = Set<String>()
        let unique = YouTubeSearchPage(videos: page.videos.filter { YouTubeURLValidator.isValidID($0.id) && ids.insert($0.id).inserted }, continuationToken: page.continuationToken)
        if generation == revision {
            if cache.count >= capacity, let oldest = cache.min(by: { $0.value.accessed < $1.value.accessed })?.key { cache.removeValue(forKey: oldest) }
            cache[key] = Entry(page: unique, expires: now().addingTimeInterval(lifetime), accessed: now())
        }
        return unique
    }
}
