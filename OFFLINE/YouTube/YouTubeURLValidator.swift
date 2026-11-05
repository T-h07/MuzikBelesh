import Foundation

enum YouTubeURLValidationError: Error, Equatable { case empty, invalidScheme, untrustedHost, unsupportedPath, invalidVideoID, malformed }

struct YouTubeURLValidator {
    static func videoID(from input: String) -> String? { try? parse(input) }
    static func isValidID(_ value: String) -> Bool { value.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil }
    static func parse(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw YouTubeURLValidationError.empty }
        if isValidID(value) { return value }
        guard let c = URLComponents(string: value) else { throw YouTubeURLValidationError.malformed }
        guard c.scheme?.lowercased() == "https" else { throw YouTubeURLValidationError.invalidScheme }
        guard let host = c.host?.lowercased(), ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"].contains(host) else { throw YouTubeURLValidationError.untrustedHost }
        guard c.user == nil, c.password == nil, c.port == nil || c.port == 443 else { throw YouTubeURLValidationError.malformed }
        // Decode once; encoded slashes may not introduce new path components.
        guard !c.percentEncodedPath.lowercased().contains("%2f"), !c.percentEncodedPath.lowercased().contains("%5c") else { throw YouTubeURLValidationError.unsupportedPath }
        let parts = c.path.split(separator: "/", omittingEmptySubsequences: false)
        let id: String
        if host == "youtu.be" {
            guard parts.count == 2 else { throw YouTubeURLValidationError.unsupportedPath }
            id = String(parts[1])
        } else if c.path == "/watch" {
            let values = c.queryItems?.filter { $0.name == "v" } ?? []
            guard values.count == 1, let value = values.first?.value else { throw YouTubeURLValidationError.invalidVideoID }
            id = value
        } else {
            guard parts.count == 3, ["shorts", "embed", "live"].contains(String(parts[1])) else { throw YouTubeURLValidationError.unsupportedPath }
            id = String(parts[2])
        }
        guard isValidID(id) else { throw YouTubeURLValidationError.invalidVideoID }
        return id
    }
}
