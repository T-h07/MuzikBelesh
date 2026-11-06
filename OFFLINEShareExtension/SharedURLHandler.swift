import UIKit
import UniformTypeIdentifiers

enum ShareInputError: Error {
    case empty, unsupported, invalid, ambiguous, tooLarge, provider
    var message: String {
        switch self {
        case .empty: return "No link was shared."
        case .unsupported: return "Share a YouTube video link from YouTube or Safari."
        case .invalid: return "This is not a supported HTTPS YouTube video link. Check the address and video ID."
        case .ambiguous: return "Share one video at a time. This item contains different links."
        case .tooLarge: return "The shared content is too large. Share just the video link."
        case .provider: return "The source app could not provide the link. Try sharing it again."
        }
    }
}

struct SharedURLHandler {
    static func videoID(from text: String) throws -> String? {
        guard text.utf8.count <= 4096 else { throw ShareInputError.tooLarge }
        var ids = Set<String>()
        for word in text.split(whereSeparator: \.isWhitespace) {
            var token = String(word)
            for (open, close) in [("<", ">"), ("(", ")"), ("\"", "\"")] where token.hasPrefix(open) && token.hasSuffix(close) && token.count >= 2 {
                token.removeFirst()
                token.removeLast()
            }
            guard token.contains("://") else { continue }
            guard token.lowercased().hasPrefix("https://"), token.components(separatedBy: "://").count == 2,
                  let id = YouTubeURLValidator.videoID(from: token) else { throw ShareInputError.invalid }
            ids.insert(id)
        }
        guard ids.count <= 1 else { throw ShareInputError.ambiguous }
        return ids.first
    }

    @MainActor static func extract(_ items: [Any], timeout: Duration = .seconds(8)) async throws -> String {
        guard !items.isEmpty else { throw ShareInputError.empty }
        guard items.count <= 8 else { throw ShareInputError.tooLarge }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var ids = Set<String>()
        var count = 0
        func include(_ text: String) throws {
            if let id = try videoID(from: text) { ids.insert(id) }
            guard ids.count <= 1 else { throw ShareInputError.ambiguous }
        }
        for object in items {
            try Task.checkCancellation()
            guard let item = object as? NSExtensionItem else { throw ShareInputError.unsupported }
            if let text = item.attributedContentText?.string { try include(text) }
            let providers = item.attachments ?? []
            count += providers.count
            guard count <= 12 else { throw ShareInputError.tooLarge }
            for provider in providers {
                var recognized = false
                var produced = false
                for type in [UTType.url, .plainText, .propertyList] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                    recognized = true
                    let value: Any?
                    do { value = try await ProviderRead().load(provider, type: type, until: deadline) }
                    catch ShareInputError.provider { continue }
                    if type == .propertyList {
                        if let dict = value as? [String: Any],
                           let page = dict[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any],
                           let link = page["pageURL"] as? String { try include(link); produced = true }
                    } else if let url = value as? URL {
                        guard !url.isFileURL else { continue }
                        guard url.scheme?.lowercased() == "https" else { throw ShareInputError.invalid }
                        try include(url.absoluteString)
                        produced = true
                    } else if let text = value as? String {
                        try include(text)
                        produced = true
                    }
                }
                if recognized && !produced { throw ShareInputError.provider }
            }
        }
        try Task.checkCancellation()
        guard let id = ids.first else { throw ShareInputError.unsupported }
        return id
    }
}

// A host can reply late or never. Settle each continuation once, including on dismissal.
@MainActor private final class ProviderRead {
    private var continuation: CheckedContinuation<Any?, Error>?
    private var timer: Task<Void, Never>?
    func load(_ provider: NSItemProvider, type: UTType, until deadline: ContinuousClock.Instant) async throws -> Any? {
        try Task.checkCancellation()
        guard .now < deadline else { throw ShareInputError.provider }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timer = Task {
                    do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                    finish(.failure(ShareInputError.provider))
                }
                provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { [weak self] value, error in
                    Task { @MainActor in
                        self?.finish(error == nil ? .success(value) : .failure(ShareInputError.provider))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }
    private func finish(_ result: Result<Any?, Error>) {
        timer?.cancel()
        timer = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}
