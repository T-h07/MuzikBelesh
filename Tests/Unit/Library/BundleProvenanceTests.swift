import XCTest

final class BundleProvenanceTests: XCTestCase {
    func testHostAppAndEmbeddedExtensionHaveMatchingNonemptyBuildVersions() throws {
        let app = Bundle.main
        let url = app.bundleURL.appendingPathComponent("PlugIns/OFFLINEShareExtension.appex/Info.plist")
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        let version = try XCTUnwrap(app.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        XCTAssertFalse(version.isEmpty); XCTAssertTrue(version.allSatisfy(\.isNumber))
        XCTAssertEqual(info["CFBundleVersion"] as? String, version)
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, app.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }
}
