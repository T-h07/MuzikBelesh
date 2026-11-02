import XCTest
@testable import OFFLINE
final class DiagnosticsStateTests: XCTestCase {
    func testProbeResultSummaryContainsSafeMetadata() { let result = YouTubeProbeResult(videoID: "dQw4w9WgXcQ", title: "Test", audioStreamCount: 1, selectedFormat: "m4a", selectedBitrate: 128, hasUsableStreamURL: true); XCTAssertTrue(result.summary.contains("Usable URL: Yes")) }
}

