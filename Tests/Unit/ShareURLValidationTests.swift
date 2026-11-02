import XCTest
@testable import OFFLINE
final class ShareURLValidationTests: XCTestCase {
    func testShareInputsUseSameStrictYouTubeValidation() { XCTAssertEqual(YouTubeURLValidator.videoID(from: "https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ"); XCTAssertNil(YouTubeURLValidator.videoID(from: "http://youtube.com/watch?v=dQw4w9WgXcQ")) }
}

