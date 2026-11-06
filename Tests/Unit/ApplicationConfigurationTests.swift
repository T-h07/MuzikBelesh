import XCTest
@testable import OFFLINE
final class ApplicationConfigurationTests: XCTestCase {
    func testConfigurationHasStableDefaults() { let c = AppConfiguration.current(bundle: Bundle(for: Marker.self), environment: [:]); XCTAssertFalse(c.bundleIdentifier.isEmpty) }
    private final class Marker: NSObject {}
}

