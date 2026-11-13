import Foundation

// The only provider-specific JSON schema lives here. Fail closed on schema drift.
enum YouTubeWebParser {
    static func object(in html: String, markers: [String]) throws -> [String: Any] {
        for marker in markers {
            var searchStart = html.startIndex
            while let range = html.range(of: marker, range: searchStart..<html.endIndex) {
                let suffix = html[range.upperBound...].drop(while: { $0.isWhitespace })
                if suffix.first == "{", let data = balancedObject(suffix),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
                searchStart = range.upperBound
            }
        }
        throw YouTubeError.searchUnavailable
    }
    private static func balancedObject(_ text: Substring) -> Data? {
        var depth = 0, quoted = false, escaped = false
        var bytes = [UInt8]()
        for byte in text.utf8 {
            bytes.append(byte)
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 { depth += 1 }
            else if byte == 125 { depth -= 1; if depth == 0 { return Data(bytes) } }
            if bytes.count > 8_000_000 { return nil }
        }
        return nil
    }
    static func text(_ node: Any?) -> String? {
        guard let node = node as? [String: Any] else { return nil }
        let result = (node["simpleText"] as? String) ?? (node["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        return result?.isEmpty == false ? result : nil
    }
    static func thumbnail(_ node: Any?) -> URL? {
        let items = (node as? [String: Any])?["thumbnails"] as? [[String: Any]] ?? []
        return items.reversed().compactMap { ($0["url"] as? String).flatMap(URL.init(string:)).flatMap(YouTubeImageURL.valid) }.first
    }
    static func duration(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        let parts = value.split(separator: ":")
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let seconds = parts.reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
        return seconds.isFinite && seconds >= 0 && seconds < 10_000_000 ? seconds : nil
    }
    static func search(_ object: [String: Any]) throws -> YouTubeSearchPage {
        var nodes: [[String: Any]] = []
        if let contents = object["contents"] as? [String: Any],
           let two = contents["twoColumnSearchResultsRenderer"] as? [String: Any],
           let primary = two["primaryContents"] as? [String: Any],
           let section = primary["sectionListRenderer"] as? [String: Any],
           let items = section["contents"] as? [[String: Any]] { nodes = items }
        else if let commands = (object["onResponseReceivedCommands"] ?? object["onResponseReceivedActions"]) as? [[String: Any]] {
            for command in commands {
                if let append = command["appendContinuationItemsAction"] as? [String: Any], let items = append["continuationItems"] as? [[String: Any]] { nodes += items }
            }
        } else { throw YouTubeError.searchUnavailable }
        var videos: [YouTubeVideo] = [], token: String?, seen = Set<String>()
        func visit(_ items: [[String: Any]]) {
            for item in items {
                if let section = item["itemSectionRenderer"] as? [String: Any], let children = section["contents"] as? [[String: Any]] { visit(children) }
                if let renderer = item["videoRenderer"] as? [String: Any], let video = video(renderer), seen.insert(video.id).inserted { videos.append(video) }
                if let renderer = item["continuationItemRenderer"] as? [String: Any],
                   let endpoint = renderer["continuationEndpoint"] as? [String: Any],
                   let command = endpoint["continuationCommand"] as? [String: Any], let value = command["token"] as? String, value.count < 16_384 { token = value }
            }
        }
        visit(nodes)
        // A known empty-results message is valid. Unknown nonempty layouts are not "no results".
        if videos.isEmpty, !containsMessage(nodes) { throw YouTubeError.searchUnavailable }
        return YouTubeSearchPage(videos: videos, continuationToken: token)
    }
    private static func containsMessage(_ nodes: [[String: Any]]) -> Bool {
        nodes.contains { node in
            // Restriction/error messages are not evidence of an empty search.
            if let message = node["messageRenderer"] as? [String: Any],
               let value = text(message["text"])?.lowercased(),
               ["no results", "no results found", "no results found."].contains(value) { return true }
            if let section = node["itemSectionRenderer"] as? [String: Any], let contents = section["contents"] as? [[String: Any]] { return containsMessage(contents) }
            return false
        }
    }
    private static func video(_ r: [String: Any]) -> YouTubeVideo? {
        guard let id = r["videoId"] as? String, YouTubeURLValidator.isValidID(id), let title = text(r["title"]) else { return nil }
        let owner = (r["ownerText"] ?? r["longBylineText"] ?? r["shortBylineText"]) as? [String: Any]
        let run = (owner?["runs"] as? [[String: Any]])?.first
        let endpoint = run?["navigationEndpoint"] as? [String: Any]
        let browse = endpoint?["browseEndpoint"] as? [String: Any]
        let overlays = r["thumbnailOverlays"] as? [[String: Any]] ?? []
        let live = overlays.contains { ($0["thumbnailOverlayTimeStatusRenderer"] as? [String: Any])?["style"] as? String == "LIVE" }
        let upcoming = r["upcomingEventData"] != nil
        let navigation = r["navigationEndpoint"] as? [String: Any]
        let web = (navigation?["commandMetadata"] as? [String: Any])?["webCommandMetadata"] as? [String: Any]
        return YouTubeVideo(id: id, title: title, channel: text(owner), channelID: browse?["browseId"] as? String,
                            thumbnailURL: thumbnail(r["thumbnail"]), duration: duration(text(r["lengthText"])),
                            availability: live ? .live : upcoming ? .upcoming : .unknown, isShort: (web?["url"] as? String)?.hasPrefix("/shorts/") == true)
    }
    static func watch(_ object: [String: Any], videoID: String) throws -> YouTubeVideo {
        guard let status = object["playabilityStatus"] as? [String: Any], let value = status["status"] as? String else { throw YouTubeError.metadataUnavailable }
        switch value {
        case "OK": break
        case "LOGIN_REQUIRED", "AGE_CHECK_REQUIRED", "CONTENT_CHECK_REQUIRED": throw YouTubeError.accessRestricted
        case "ERROR": throw YouTubeError.videoUnavailable
        case "UNPLAYABLE": throw YouTubeError.videoUnavailable // no speculative region diagnosis
        case "LIVE_STREAM_OFFLINE": throw YouTubeError.streamNotReady
        default: throw YouTubeError.accessRestricted
        }
        guard let details = object["videoDetails"] as? [String: Any], details["videoId"] as? String == videoID,
              let title = details["title"] as? String, !title.isEmpty else { throw YouTubeError.metadataUnavailable }
        return YouTubeVideo(id: videoID, title: title, channel: details["author"] as? String, channelID: details["channelId"] as? String,
                            thumbnailURL: thumbnail(details["thumbnail"]), duration: duration(details["lengthSeconds"] as? String),
                            availability: details["isLiveContent"] as? Bool == true && details["isLive"] as? Bool == true ? .live : .available)
    }
}
