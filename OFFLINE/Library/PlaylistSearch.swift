import Foundation

/// Search inside one playlist. It only decides which rows are *shown*: it never changes
/// playlist membership or order, and playback always uses the full playlist (tapping a
/// result plays that exact occurrence and continues through the whole playlist).
///
/// Matching is local, immediate and case-, diacritic- and width-insensitive ("endrra"
/// finds "Ëndrra"). Every word of the query must appear in the song's title or artists.
enum PlaylistSearch {
    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func terms(_ query: String) -> [String] {
        normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func matches(_ fields: [String?], terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let haystack = fields.compactMap { $0 }.map(normalized).joined(separator: " ")
        return terms.allSatisfy { haystack.contains($0) }
    }

    /// Filters in place-order: the result keeps the playlist's own order and the items'
    /// own identities (occurrence IDs), so duplicates stay distinct.
    static func filter<Item>(_ items: [Item], query: String, fields: (Item) -> [String?]) -> [Item] {
        let words = Self.terms(query)
        guard !words.isEmpty else { return items }
        return items.filter { matches(fields($0), terms: words) }
    }
}
