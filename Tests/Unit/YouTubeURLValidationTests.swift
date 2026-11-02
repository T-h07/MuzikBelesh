import XCTest
@testable import OFFLINE
final class YouTubeURLValidationTests: XCTestCase {
    func testAcceptedFormats() { XCTAssertEqual(YouTubeURLValidator.videoID(from: "dQw4w9WgXcQ"), "dQw4w9WgXcQ"); XCTAssertEqual(YouTubeURLValidator.videoID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ"); XCTAssertEqual(YouTubeURLValidator.videoID(from: "https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ"); XCTAssertEqual(YouTubeURLValidator.videoID(from: "https://youtube.com/shorts/dQw4w9WgXcQ"), "dQw4w9WgXcQ") }
    func testRejectsMalformedOrForeignInput() { XCTAssertNil(YouTubeURLValidator.videoID(from: "")); XCTAssertNil(YouTubeURLValidator.videoID(from: "https://example.com/watch?v=dQw4w9WgXcQ")); XCTAssertNil(YouTubeURLValidator.videoID(from: "abc")) }
}

