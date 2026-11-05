import Foundation

enum YouTubeURLValidationError: Error, Equatable { case empty, invalidScheme, untrustedHost, unsupportedPath, invalidVideoID, malformed }

struct YouTubeURLValidator {
    static func videoID(from input: String) -> String? { try? parse(input) }
    static func isValidID(_ value: String) -> Bool { value.utf8.count == 11 && value.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil }
    static func parse(_ input: String) throws -> String {
        guard input.utf8.count <= 4096 else { throw YouTubeURLValidationError.malformed }
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw YouTubeURLValidationError.empty }
        if isValidID(value) { return value }
        guard let c = URLComponents(string: value, encodingInvalidCharacters: false) else { throw YouTubeURLValidationError.malformed }
        guard c.scheme?.lowercased() == "https" else { throw YouTubeURLValidationError.invalidScheme }
        guard let host = c.percentEncodedHost?.lowercased(), ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"].contains(host) else { throw YouTubeURLValidationError.untrustedHost }
        guard c.user == nil, c.password == nil, c.port == nil || c.port == 443 else { throw YouTubeURLValidationError.malformed }
        // Split before decoding so an encoded slash cannot introduce a route component.
        guard !value.contains("\\"),
              !value.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw YouTubeURLValidationError.unsupportedPath }
        let parts = c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        let id: String
        if host == "youtu.be" {
            guard parts.count == 2 else { throw YouTubeURLValidationError.unsupportedPath }
            guard let decoded = parts[1].removingPercentEncoding else { throw YouTubeURLValidationError.invalidVideoID }
            id = decoded
        } else if c.percentEncodedPath == "/watch" {
            let values = c.queryItems?.filter { $0.name == "v" } ?? []
            guard values.count == 1, let value = values.first?.value else { throw YouTubeURLValidationError.invalidVideoID }
            id = value
        } else {
            guard parts.count == 3, ["shorts", "embed", "live"].contains(String(parts[1])) else { throw YouTubeURLValidationError.unsupportedPath }
            guard let decoded = parts[2].removingPercentEncoding else { throw YouTubeURLValidationError.invalidVideoID }
            id = decoded
        }
        guard isValidID(id) else { throw YouTubeURLValidationError.invalidVideoID }
        return id
    }
}
