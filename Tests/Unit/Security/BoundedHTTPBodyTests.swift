import XCTest
@testable import OFFLINE

/// Serves deterministic bodies chosen by URL path; no real network.
private final class SizedBodyProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        let (declared, chunks): (Int?, [Int]) = switch path {
        case "/declared-oversize": (10_000, [10_000])
        case "/streamed-oversize": (nil, Array(repeating: 1_024, count: 8))
        case "/exact": (nil, [4_096])
        case "/youtube-oversize": (nil, Array(repeating: 1_000_000, count: 9))
        default: (nil, [5])
        }
        var headers = ["Content-Type": "application/json"]
        if let declared { headers["Content-Length"] = String(declared) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for size in chunks { client?.urlProtocol(self, didLoad: Data(repeating: 0x61, count: size)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

/// Phase 12 security: response size limits are enforced while streaming, so an oversized
/// or endless body is rejected without first being buffered in full.
final class BoundedHTTPBodyTests: XCTestCase {
    private var session: URLSession!
    override func setUp() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SizedBodyProtocol.self]
        session = URLSession(configuration: configuration)
    }
    override func tearDown() { session.invalidateAndCancel(); session = nil }

    private func read(_ path: String, limit: Int = 4_096) async throws -> Data {
        try await BoundedHTTPBody.read(session, URLRequest(url: URL(string: "https://bounded.test" + path)!), limit: limit).0
    }

    func testDeclaredOversizeIsRejectedBeforeReading() async {
        do { _ = try await read("/declared-oversize"); XCTFail("Accepted an oversized declared body") }
        catch { XCTAssertEqual(error as? BoundedHTTPBody.TooLarge, .init(status: 200, contentType: "application/json")) }
    }

    func testUndeclaredOversizeIsRejectedWhileStreaming() async {
        do { _ = try await read("/streamed-oversize"); XCTFail("Accepted an oversized streamed body") }
        catch { XCTAssertTrue(error is BoundedHTTPBody.TooLarge, "\(error)") }
    }

    func testBodiesUpToTheLimitAreReturnedIntact() async throws {
        let exact = try await read("/exact")
        XCTAssertEqual(exact, Data(repeating: 0x61, count: 4_096))
        let small = try await read("/small")
        XCTAssertEqual(small, Data(repeating: 0x61, count: 5))
    }

    func testYouTubeTransportRejectsOversizedResponses() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SizedBodyProtocol.self]
        let transport = YouTubeURLSessionTransport(configuration: configuration)
        XCTAssertEqual(YouTubeURLSessionTransport.maximumResponseBytes, 8_000_000)
        do {
            _ = try await transport.send(YouTubeHTTP.request(URL(string: "https://www.youtube.com/youtube-oversize")!))
            XCTFail("Accepted a 9 MB YouTube response")
        } catch { XCTAssertEqual(error as? YouTubeError, .searchUnavailable) }
    }

    func testDiscoveryLimitIsUnchanged() {
        XCTAssertEqual(SearXNGURLSessionTransport.maximumResponseBytes, 4_000_000)
    }
}
