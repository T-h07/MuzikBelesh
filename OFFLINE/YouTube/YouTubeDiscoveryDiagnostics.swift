import Foundation
import OSLog

enum YouTubeDiscoveryStage: String, Sendable {
    case request, transport, transportResponse, transportSize, transportRedirect, http, responseType
    case htmlEncoding, htmlExtraction, jsonDecoding, searchStructure, resultRenderers, watchStructure
}
enum YouTubeResponseType: String, Sendable {
    case html, json, other, unknown
    init(_ value: String?) {
        guard let value else { self = .unknown; return }
        switch value.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) {
        case "text/html": self = .html
        case "application/json", "text/json": self = .json
        default: self = .other
        }
    }
}
enum YouTubeDiscoveryOperation: String, Sendable { case search, metadata, transport }
struct YouTubeDiscoveryDiagnostic: Sendable {
    let stage: YouTubeDiscoveryStage
    let category: YouTubeError
    let status: Int?
    let responseType: YouTubeResponseType
    var operation: YouTubeDiscoveryOperation = .search
}
enum YouTubeDiscoveryDiagnostics {
    private static let log = Logger(subsystem: "com.th07.muzikbelesh", category: "YouTubeDiscovery")
    static func record(_ event: YouTubeDiscoveryDiagnostic) {
        // Fixed enums and numeric status only; never URLs, queries, headers or bodies.
        log.error("operation=\(event.operation.rawValue, privacy: .public) stage=\(event.stage.rawValue, privacy: .public) category=\(event.category.rawValue, privacy: .public) http=\(event.status ?? 0, privacy: .public) response=\(event.responseType.rawValue, privacy: .public)")
    }
}
enum YouTubeParserFailure: Error {
    case missingObject, malformedObject, searchStructure, resultRenderers
    var stage: YouTubeDiscoveryStage {
        switch self {
        case .missingObject: return .htmlExtraction
        case .malformedObject: return .jsonDecoding
        case .searchStructure: return .searchStructure
        case .resultRenderers: return .resultRenderers
        }
    }
}
