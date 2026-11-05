import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import OFFLINE

final class ShareURLValidationTests: XCTestCase {
    private let id = "dQw4w9WgXcQ"
    private var url: String { "https://youtu.be/" + id }

    func testEquivalentURLsAndTracking() throws {
        for value in ["https://www.youtube.com/watch?v=", "https://youtube.com/watch?v=",
                      "https://m.youtube.com/watch?v=", "https://youtu.be/",
                      "https://www.youtube.com/shorts/", "https://youtube.com/live/", "https://youtube.com/embed/"] {
            XCTAssertEqual(try SharedURLHandler.videoID(from: "  \n" + value + id + (value.hasSuffix("=") ? "&" : "?") + "si=ignored "), id)
        }
        XCTAssertEqual(try SharedURLHandler.videoID(from: "My song\n<" + url + ">"), id)
    }

    func testInvalidInputs() {
        for input in ["", id, "https://youtu.be/short", "http://youtu.be/" + id,
                      "https://x.youtube.com/watch?v=" + id, "https://youtube.com.evil/watch?v=" + id,
                      "https://example.org@" + String(url.dropFirst(8)), "https://youtu.be:81/" + id,
                      "https://youtube.com/shorts%2F" + id, "file:///tmp/" + id,
                      "https://", url + String(repeating: "a", count: 4096),
                      url + " https://other.example/path", url + " https://youtu.be/9bZkp7q19f0"] {
            XCTAssertNil(try? SharedURLHandler.videoID(from: input), input)
        }
    }

    private func item(_ providers: [NSItemProvider]) -> NSExtensionItem {
        let item = NSExtensionItem()
        item.attachments = providers
        return item
    }

    @MainActor func testMultipleProviderRepresentationsAndSafari() async throws {
        let link = NSItemProvider(item: URL(string: url)! as NSURL, typeIdentifier: UTType.url.identifier)
        let text = NSItemProvider(item: ("My song\n" + url) as NSString, typeIdentifier: UTType.plainText.identifier)
        let page = [NSExtensionJavaScriptPreprocessingResultsKey: ["pageURL": url]] as NSDictionary
        let safari = NSItemProvider(item: page, typeIdentifier: UTType.propertyList.identifier)
        for items in [[item([link]), item([text])], [item([text])], [item([safari])]] {
            let result = try await SharedURLHandler.extract(items)
            XCTAssertEqual(result, id)
        }
    }

    @MainActor func testRejectsMissingConflictingAndMalformedProviders() async {
        let providers = [url, "https://youtu.be/9bZkp7q19f0"].map {
            NSItemProvider(item: $0 as NSString, typeIdentifier: UTType.plainText.identifier)
        }
        for items in [[], [item([])], [item(providers)], [item([NSItemProvider(item: NSData(), typeIdentifier: UTType.data.identifier)])],
                      [item([NSItemProvider(item: URL(fileURLWithPath: "/tmp/test") as NSURL, typeIdentifier: UTType.url.identifier)])]] {
            do { _ = try await SharedURLHandler.extract(items); XCTFail("Unexpected delivery") }
            catch { XCTAssertTrue(error is ShareInputError) }
        }
    }

    @MainActor func testProviderFailureDeadlineAndCancellation() async {
        let provider = NSItemProvider()
        provider.registerItem(forTypeIdentifier: UTType.url.identifier, loadHandler: { _, _, _ in })
        do { _ = try await SharedURLHandler.extract([item([provider])], timeout: .milliseconds(50)); XCTFail() }
        catch { XCTAssertTrue(error is ShareInputError) }
        let task = Task { try await SharedURLHandler.extract([item([provider])]) }
        await Task.yield()
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
}
