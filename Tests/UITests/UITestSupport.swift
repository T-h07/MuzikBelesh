import XCTest

/// Shared, bounded XCUITest interactions. See Docs/TESTING_RELIABILITY.md.
///
/// Every check below costs an accessibility snapshot of the app, which is slow for long
/// lists. Loops therefore stop the moment their condition holds. Never write
/// `for _ in 0..<n where !condition { swipe }`: Swift's `where` only skips the body, so the
/// loop keeps evaluating (snapshotting) the condition for every remaining iteration.
extension XCUIElement {
    /// In the hierarchy and able to receive a tap.
    var isVisible: Bool { exists && isHittable }
}

enum ScrollDirection {
    /// Reveal content further down (swipe up).
    case down
    /// Reveal content further up (swipe down).
    case up
}

extension XCTestCase {
    /// Swipes `container` until `element` is visible, stopping as soon as it is.
    /// Returns false (without failing) when `maxSwipes` is exhausted.
    @discardableResult
    func scroll(_ container: XCUIElement, toReveal element: XCUIElement, _ direction: ScrollDirection = .down,
                maxSwipes: Int = 8, velocity: XCUIGestureVelocity = .default) -> Bool {
        var swipes = 0
        while !element.isVisible {
            guard swipes < maxSwipes else { return false }
            switch direction {
            case .down: container.swipeUp(velocity: velocity)
            case .up: container.swipeDown(velocity: velocity)
            }
            swipes += 1
        }
        return true
    }

    /// Lazily rendered rows may be missing from the tree until scrolled to (below) or after
    /// being scrolled past (above): search down first, then back up. Fails with context.
    func reveal(_ element: XCUIElement, in container: XCUIElement, maxSwipes: Int = 8,
                file: StaticString = #filePath, line: UInt = #line) {
        if scroll(container, toReveal: element, .down, maxSwipes: maxSwipes, velocity: .slow) { return }
        if scroll(container, toReveal: element, .up, maxSwipes: maxSwipes * 2, velocity: .slow) { return }
        XCTFail("\(element.identifier.isEmpty ? element.description : element.identifier) never became tappable", file: file, line: line)
    }

    /// Waits for a state transition instead of asserting immediately after an action.
    @discardableResult
    func waitUntil(_ element: XCUIElement, _ predicate: String, _ arguments: CVarArg..., timeout: TimeInterval = 5,
                   message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate, argumentArray: arguments), object: element)
        let completed = XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
        if !completed { XCTFail("Timed out waiting for \(predicate) \(arguments). \(message())", file: file, line: line) }
        return completed
    }

    /// A List-row Toggle's accessibility frame (and, on iOS 26, its nested switch's frame)
    /// spans the whole row; its centre is the label, which does not flip the switch. The
    /// control is trailing-aligned, so tap 30 pt in from the trailing edge and wait for the
    /// value to change.
    func flipSwitch(_ row: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let before = row.value as? String ?? ""
        let width = max(row.frame.width, 1)
        row.coordinate(withNormalizedOffset: CGVector(dx: max(0.5, (width - 30) / width), dy: 0.5)).tap()
        // A tap that lands while the list is still settling from a scroll can be absorbed by
        // the scroll view (flaky in CI #294/#298). Retry once on the nested control only when
        // the value provably did not change; the final assertion is unchanged.
        let changed = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", before), object: row)], timeout: 3) == .completed
        if !changed {
            let inner = row.switches.firstMatch
            if inner.exists && inner.isHittable { inner.tap() } else { row.coordinate(withNormalizedOffset: CGVector(dx: max(0.5, (width - 30) / width), dy: 0.5)).tap() }
        }
        waitUntil(row, "value != %@", before, timeout: 3, message: "\(row.identifier) did not change from \(before)", file: file, line: line)
    }

    /// Failure evidence: one screenshot and one hierarchy dump, captured only on failure.
    func attachFailureEvidence(_ app: XCUIApplication?) {
        guard let app, (testRun?.failureCount ?? 0) > 0 else { return }
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways; add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription); tree.lifetime = .keepAlways; add(tree)
    }
}
