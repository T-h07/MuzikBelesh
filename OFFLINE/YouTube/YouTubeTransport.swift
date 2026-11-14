import Foundation

struct YouTubeHTTPResponse: Sendable {
    let data: Data
    let status: Int
    let url: URL
    let contentType: String?
    var redirect: YouTubeRedirectCategory? = nil
}
protocol YouTubeTransport: Sendable {
    func send(_ request: URLRequest) async throws -> YouTubeHTTPResponse
}

/// Only fixed categories leave the transport; Location may contain private queries.
enum YouTubeRedirectCategory: String, Sendable {
    case youtube, media, artwork, consent, login, verification, external, unsafe, unsupported, limit
    var restricted: Bool { [.consent, .login, .verification].contains(self) }
    static func classify(_ url: URL?) -> Self {
        guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return .unsafe }
        let path = url.path.lowercased()
        if ["consent.youtube.com", "consent.google.com"].contains(host) { return .consent }
        if ["accounts.youtube.com", "accounts.google.com"].contains(host) { return .login }
        let web = ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(host)
        if web || ["google.com", "www.google.com"].contains(host) {
            if path == "/sorry" || path.hasPrefix("/sorry/") || path == "/challenge" || path.hasPrefix("/challenge/") { return .verification }
        }
        if web {
            if path == "/consent" || path.hasPrefix("/consent/") { return .consent }
            if path == "/signin" || path.hasPrefix("/signin/") || path == "/login" { return .login }
            return ["/results", "/watch", "/youtubei/v1/search"].contains(path) ? .youtube : .unsupported
        }
        if host == "googlevideo.com" || host.hasSuffix(".googlevideo.com") { return .media }
        if YouTubeImageURL.valid(url) != nil { return .artwork }
        return .external
    }
}

/// One delegate per request: concurrent artwork/search cannot overwrite redirect state.
final class YouTubeRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var last: YouTubeRedirectCategory?
    private var count = 0
    var category: YouTubeRedirectCategory? { lock.lock(); defer { lock.unlock() }; return last }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        count += 1
        let destination = YouTubeRedirectCategory.classify(request.url)
        last = count > 5 ? .limit : destination
        let withinLimit = count <= 5
        lock.unlock()
        let original = task.originalRequest
        let origin = YouTubeRedirectCategory.classify(original?.url)
        // Preserve endpoint purpose and method, including POST continuation bodies.
        // No same-host sign-in/challenge pages, cross-purpose redirects or downgrades.
        let sameKind = origin == destination && [.youtube, .media, .artwork].contains(destination)
        let sameEndpoint = origin != .youtube || original?.url?.path == request.url?.path
        guard withinLimit, sameKind, sameEndpoint, original?.httpMethod == request.httpMethod else {
            completionHandler(nil); return
        }
        var safe = request
        safe.httpShouldHandleCookies = false
        safe.setValue(nil, forHTTPHeaderField: "Cookie")
        safe.setValue(nil, forHTTPHeaderField: "Authorization")
        if safe.httpMethod == "POST" { safe.httpBody = original?.httpBody }
        completionHandler(safe)
    }
}

final class YouTubeURLSessionTransport: YouTubeTransport, @unchecked Sendable {
    private let session: URLSession
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration)
    }
    deinit { session.invalidateAndCancel() }
    static func permitted(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "www.youtube.com" || host == "youtube.com" || host == "m.youtube.com" || host == "googlevideo.com" || host.hasSuffix(".googlevideo.com") || YouTubeImageURL.valid(url) != nil
    }
    func send(_ request: URLRequest) async throws -> YouTubeHTTPResponse {
        guard let url = request.url, Self.permitted(url) else { throw YouTubeError.invalidURL }
        var request = request
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 15
        let redirects = YouTubeRedirectDelegate()
        let (data, response) = try await session.data(for: request, delegate: redirects)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            YouTubeDiscoveryDiagnostics.record(.init(stage: .transportResponse, category: .searchUnavailable, status: nil, responseType: .unknown, operation: .transport))
            throw YouTubeError.searchUnavailable
        }
        guard let finalURL = response.url, Self.permitted(finalURL), data.count <= 8_000_000 else {
            YouTubeDiscoveryDiagnostics.record(.init(stage: data.count > 8_000_000 ? .transportSize : .transportRedirect,
                category: .searchUnavailable, status: response.statusCode, responseType: .init(response.value(forHTTPHeaderField: "Content-Type")), operation: .transport))
            throw YouTubeError.searchUnavailable
        }
        // Also classify a Location if Foundation returns a redirect without a callback.
        let location = response.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: finalURL)?.absoluteURL }
        let redirect = redirects.category ?? ((300..<400).contains(response.statusCode) ? YouTubeRedirectCategory.classify(location) : nil)
        return YouTubeHTTPResponse(data: data, status: response.statusCode, url: finalURL, contentType: response.value(forHTTPHeaderField: "Content-Type"), redirect: redirect)
    }
}

enum YouTubeHTTP {
    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
        request.httpShouldHandleCookies = false
        return request
    }
    static func successful(_ response: YouTubeHTTPResponse, fallback: YouTubeError) throws {
        switch response.status {
        case 200..<300: return
        case 300..<400: throw response.redirect?.restricted == true ? YouTubeError.providerRestricted : .redirectUnavailable
        case 401, 403: throw YouTubeError.accessRestricted
        case 404, 410: throw YouTubeError.videoUnavailable
        case 408, 504: throw YouTubeError.requestTimeout
        case 429: throw YouTubeError.rateLimited
        default: throw fallback
        }
    }
}
