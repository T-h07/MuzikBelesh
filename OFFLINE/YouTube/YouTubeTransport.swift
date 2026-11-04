import Foundation

struct YouTubeHTTPResponse: Sendable {
    let data: Data
    let status: Int
    let url: URL
    let contentType: String?
}
protocol YouTubeTransport: Sendable {
    func send(_ request: URLRequest) async throws -> YouTubeHTTPResponse
}

final class YouTubeURLSessionTransport: NSObject, YouTubeTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let session: URLSession
    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration)
        super.init()
    }
    static func permitted(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "www.youtube.com" || host == "youtube.com" || host == "googlevideo.com" || host.hasSuffix(".googlevideo.com") || YouTubeImageURL.valid(url) != nil
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never follow consent/login/foreign redirects or send a media request to the web host.
        let media = task.originalRequest?.httpMethod == "HEAD"
        if media && request.httpMethod != "HEAD" { completionHandler(nil); return }
        let artwork = YouTubeImageURL.valid(task.originalRequest?.url) != nil
        let sameKind = artwork ? YouTubeImageURL.valid(request.url) != nil : media ? request.url?.host?.hasSuffix(".googlevideo.com") == true : request.url?.host == "www.youtube.com" || request.url?.host == "youtube.com"
        completionHandler(request.url.map(Self.permitted) == true && sameKind ? request : nil)
    }
    func send(_ request: URLRequest) async throws -> YouTubeHTTPResponse {
        guard let url = request.url, Self.permitted(url) else { throw YouTubeError.invalidURL }
        var request = request
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request, delegate: self)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, let finalURL = response.url, Self.permitted(finalURL), data.count <= 8_000_000 else { throw YouTubeError.searchUnavailable }
        return YouTubeHTTPResponse(data: data, status: response.statusCode, url: finalURL, contentType: response.value(forHTTPHeaderField: "Content-Type"))
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
        case 401, 403: throw YouTubeError.accessRestricted
        case 404, 410: throw YouTubeError.videoUnavailable
        case 408, 504: throw YouTubeError.requestTimeout
        case 429: throw YouTubeError.rateLimited
        default: throw fallback
        }
    }
}
