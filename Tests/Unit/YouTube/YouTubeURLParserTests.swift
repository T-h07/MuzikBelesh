import XCTest
@testable import OFFLINE

final class YouTubeURLParserTests: XCTestCase {
    func testEverySupportedFormatAndIdentityIgnoringParameters() throws {
        let id = "Abc_123-xyz"
        for input in [id, " https://www.youtube.com/watch?v=\(id) \n", "https://youtube.com/watch?v=\(id)&t=12&list=PLx&index=2&si=x", "https://m.youtube.com/watch?v=\(id)", "https://youtu.be/\(id)?si=abc&t=2", "https://www.youtube.com/shorts/\(id)", "https://youtube.com/embed/\(id)", "https://www.youtube.com/live/\(id)", "https://youtube.com/watch?v=%41bc_123-xyz", "https://youtu.be/%41bc_123-xyz", "https://WWW.YOUTUBE.COM/watch?v=\(id)"] {
            XCTAssertEqual(try YouTubeURLValidator.parse(input), id, input)
        }
    }
    func testMalformedAndMaliciousURLsAreRejected() {
        for input in ["", " \n ", "short", "abcdefghijkl", "abcdefghij!", "https://youtube.com.attacker.example/watch?v=Abc_123-xyz", "https://attacker.youtube.com/watch?v=Abc_123-xyz", "http://youtube.com/watch?v=Abc_123-xyz", "javascript:Abc_123-xyz", "file:///Abc_123-xyz", "https://youtube.com:444/watch?v=Abc_123-xyz", "https://user:pass@youtube.com/watch?v=Abc_123-xyz", "https://youtube.com/not-watch?v=Abc_123-xyz", "https://youtu.be/Abc_123-xyz/extra", "https://youtube.com/x/shorts/Abc_123-xyz", "https://youtube.com/watch?v=Abc_123-xyz&v=dQw4w9WgXcQ", "https://youtube.com/watch?v=%2541bc_123-xyz", "https://youtube.com/embed%2FAbc_123-xyz", "https://youtube.com/playlist?list=abc", "https://youtube.com/watch?v=Abc%20123-xyz", "https://youtube.com//shorts/Abc_123-xyz"] {
            XCTAssertThrowsError(try YouTubeURLValidator.parse(input), input)
        }
    }
    func testTypedValidationAndCanonicalIdentity() throws {
        XCTAssertThrowsError(try YouTubeURLValidator.parse("")) { XCTAssertEqual($0 as? YouTubeURLValidationError, .empty) }
        XCTAssertThrowsError(try YouTubeURLValidator.parse("https://youtu.be/abc")) { XCTAssertEqual($0 as? YouTubeURLValidationError, .invalidVideoID) }
        let id = try YouTubeURLValidator.parse("https://m.youtube.com/watch?v=9bZkp7q19f0&list=anything")
        XCTAssertEqual(YouTubeVideo(id: id, title: "").canonicalURL?.absoluteString, "https://www.youtube.com/watch?v=9bZkp7q19f0")
    }
}
