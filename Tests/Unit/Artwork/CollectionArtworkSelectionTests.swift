import Foundation
import SwiftUI
import XCTest
@testable import OFFLINE

/// Phase 11.5 mosaic selection: pure and deterministic (no clock, files or randomness).
final class CollectionArtworkSelectionTests: XCTestCase {
    private func covers(_ count: Int) -> [String] { (0..<count).map { "cover-\($0).jpg" } }
    private let mosaicA = CollectionArtworkIdentity.playlist("mosaic-a")

    func testFourDistinctCoversAreSelectedWhenMoreExist() throws {
        let candidates = covers(8)
        for epoch in [0, 1, 944_444, 1_000_000] {
            let selection = try XCTUnwrap(CollectionArtworkSelector.select(candidates, identity: mosaicA, epoch: epoch))
            let tiles = selection.tiles.compactMap { $0 }
            XCTAssertEqual(tiles.count, 4)
            XCTAssertEqual(Set(tiles).count, 4, "No cover may fill two quadrants when alternatives exist")
            XCTAssertTrue(Set(tiles).isSubset(of: Set(candidates)))
        }
    }

    func testSameCollectionAndEpochAlwaysSelectTheSameCovers() {
        let candidates = covers(12)
        let first = CollectionArtworkSelector.select(candidates, identity: mosaicA, epoch: 42)
        for _ in 0..<20 { XCTAssertEqual(CollectionArtworkSelector.select(candidates, identity: mosaicA, epoch: 42), first) }
        XCTAssertEqual(CollectionArtworkSelector.seed(mosaicA), CollectionArtworkSelector.seed(.playlist("mosaic-a")))
    }

    func testDifferentCollectionsSelectIndependently() {
        let candidates = covers(8)
        let other = CollectionArtworkIdentity.playlist("mosaic-b")
        let differs = (0..<5).contains { epoch in
            CollectionArtworkSelector.select(candidates, identity: mosaicA, epoch: epoch) != CollectionArtworkSelector.select(candidates, identity: other, epoch: epoch)
        }
        XCTAssertTrue(differs)
        XCTAssertNotEqual(CollectionArtworkSelector.seed(.playlist("x")), CollectionArtworkSelector.seed(.album("x")), "The kind is part of the identity")
    }

    func testNewEpochsNeverRepeatThePreviousSetAndShowEveryCover() throws {
        let identity = CollectionArtworkIdentity.album("rotation")
        for count in 5...12 {
            let candidates = covers(count)
            for epoch in 0..<40 {
                let current = try XCTUnwrap(CollectionArtworkSelector.select(candidates, identity: identity, epoch: epoch))
                let next = try XCTUnwrap(CollectionArtworkSelector.select(candidates, identity: identity, epoch: epoch + 1))
                XCTAssertNotEqual(Set(current.tiles), Set(next.tiles), "\(count) covers: epoch \(epoch) repeated")
            }
            var seen = Set<String>()
            for epoch in 1000..<(1000 + 2 * count) { seen.formUnion(CollectionArtworkSelector.select(candidates, identity: identity, epoch: epoch)?.tiles.compactMap { $0 } ?? []) }
            XCTAssertEqual(seen, Set(candidates), "\(count) covers: every cover appears within two passes")
        }
    }

    func testVarietyAcrossEpochsForEightCovers() {
        let candidates = covers(8)
        let sets = Set((0..<24).compactMap { CollectionArtworkSelector.select(candidates, identity: mosaicA, epoch: $0).map { Set($0.tiles.compactMap { $0 }) } })
        XCTAssertGreaterThan(sets.count, 2, "Eight covers must not alternate between the same two subsets")
    }

    func testExactlyFourCoversAreAllShownWithoutShuffling() {
        let candidates = covers(4)
        let expected = CollectionMosaicSelection(tiles: candidates.map { Optional($0) })
        for epoch in [0, 1, 2, 99, 944_444] { XCTAssertEqual(CollectionArtworkSelector.select(candidates, identity: mosaicA, epoch: epoch), expected) }
    }

    func testFewerThanFourCoversUseFixedCellsAndNeutralTiles() {
        let identity = CollectionArtworkIdentity.playlist("partial")
        XCTAssertNil(CollectionArtworkSelector.select([], identity: identity, epoch: 0))
        for epoch in [0, 1, 7, 944_444] {
            XCTAssertEqual(CollectionArtworkSelector.select(["a.jpg"], identity: identity, epoch: epoch)?.tiles, ["a.jpg", nil, nil, nil])
            XCTAssertEqual(CollectionArtworkSelector.select(["a.jpg", "b.jpg"], identity: identity, epoch: epoch)?.tiles, ["a.jpg", nil, nil, "b.jpg"])
            XCTAssertEqual(CollectionArtworkSelector.select(["a.jpg", "b.jpg", "c.jpg"], identity: identity, epoch: epoch)?.tiles, ["a.jpg", "b.jpg", "c.jpg", nil])
        }
        XCTAssertEqual(CollectionArtworkSelector.select(["a.jpg", "b.jpg"], identity: identity, epoch: 0)?.coverCount, 2)
    }

    func testCandidatesAreDistinctSafeAndOrderIndependent() {
        let raw: [String?] = ["b.jpg", "a.jpg", "b.jpg", nil, "../escape.jpg", "/absolute.jpg", "nested/a.jpg", ".hidden.jpg", "", "back\\slash.jpg", "a.jpg"]
        XCTAssertEqual(CollectionArtworkSelector.candidates(raw), ["a.jpg", "b.jpg"])
        XCTAssertEqual(CollectionArtworkSelector.candidates(raw, excluding: ["a.jpg"]), ["b.jpg"])
        XCTAssertEqual(CollectionArtworkSelector.candidates(raw.reversed()), CollectionArtworkSelector.candidates(raw))
        for path in ["../x.jpg", "/x.jpg", "a/b.jpg", ".x.jpg", "", String(repeating: "x", count: 300)] {
            XCTAssertFalse(CollectionArtworkSelector.isSafeManagedPath(path), path)
        }
        XCTAssertTrue(CollectionArtworkSelector.isSafeManagedPath("artwork-0F8C2D0E-6C3B-4E7A-9C61-2B6E4C1B7A10.jpg"))
    }

    func testReorderingTheSameSongsKeepsTheMosaic() {
        let paths: [String?] = (0..<9).map { "cover-\($0).jpg" }
        let forward = CollectionArtworkSelector.candidates(paths)
        let shuffled = CollectionArtworkSelector.candidates([paths[4], paths[0], paths[8], paths[2], paths[6], paths[1], paths[7], paths[3], paths[5]])
        XCTAssertEqual(CollectionArtworkSelector.select(forward, identity: mosaicA, epoch: 3), CollectionArtworkSelector.select(shuffled, identity: mosaicA, epoch: 3))
    }

    func testLargeCollectionsSelectInConstantWork() throws {
        let candidates = covers(10_000)
        let start = Date()
        for epoch in 0..<2_000 {
            let selection = try XCTUnwrap(CollectionArtworkSelector.select(candidates, identity: mosaicA, epoch: epoch))
            XCTAssertEqual(Set(selection.tiles.compactMap { $0 }).count, 4)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "Selection reads four elements; it never re-sorts or copies the candidates")
    }

    func testAffinePermutationIsABijection() {
        for count in [1, 2, 3, 5, 8, 12, 97, 1000] {
            for seed: UInt64 in [0, 1, 0xdead_beef, .max] {
                let permutation = AffinePermutation(count: count, seed: seed)
                XCTAssertEqual(Set((0..<count).map(permutation.index)).count, count)
            }
        }
    }

    func testEpochFollowsTheConfiguredInterval() {
        XCTAssertEqual(CollectionArtworkSelector.epoch(at: Date(timeIntervalSince1970: 1800 * 10 + 1799), interval: 1800), 10)
        XCTAssertEqual(CollectionArtworkSelector.epoch(at: Date(timeIntervalSince1970: 1800 * 11), interval: 1800), 11)
        XCTAssertEqual(CollectionArtworkSelector.epoch(at: Date(timeIntervalSince1970: 500), interval: 0), 0)
        XCTAssertEqual(CollectionArtworkService.defaultInterval, 30 * 60)
    }

    // MARK: Effective artwork precedence

    private let entry = CollectionArtworkEntry(customPath: "custom.jpg", candidates: ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"], firstPath: "c.jpg")

    func testCustomCoverAlwaysWins() {
        for enabled in [true, false] {
            XCTAssertEqual(CollectionArtworkSelector.presentation(entry: entry, mosaicEnabled: enabled, identity: mosaicA, epoch: 1), .custom("custom.jpg"))
        }
    }

    func testWithoutCustomCoverTheMosaicOrSingleCoverIsShown() throws {
        var automatic = entry; automatic.customPath = nil
        guard case .mosaic(let selection) = CollectionArtworkSelector.presentation(entry: automatic, mosaicEnabled: true, identity: mosaicA, epoch: 1) else { return XCTFail("Mosaic expected") }
        XCTAssertEqual(selection.coverCount, 4)
        XCTAssertEqual(CollectionArtworkSelector.presentation(entry: automatic, mosaicEnabled: false, identity: mosaicA, epoch: 1), .single("c.jpg"), "Static mode keeps the legacy first song cover")
        XCTAssertEqual(CollectionArtworkSelector.presentation(entry: .empty, mosaicEnabled: true, identity: mosaicA, epoch: 1), .placeholder)
        XCTAssertEqual(CollectionArtworkSelector.presentation(entry: nil, mosaicEnabled: true, identity: mosaicA, epoch: 1), .placeholder)
    }

    func testUnusableOrUnsafeCustomCoversFallThrough() {
        guard case .mosaic = CollectionArtworkSelector.presentation(entry: entry, mosaicEnabled: true, identity: mosaicA, epoch: 1, unusable: ["custom.jpg"]) else { return XCTFail("A missing custom cover reveals the mosaic") }
        var unsafe = entry; unsafe.customPath = "../custom.jpg"
        guard case .mosaic = CollectionArtworkSelector.presentation(entry: unsafe, mosaicEnabled: true, identity: mosaicA, epoch: 1) else { return XCTFail("An unsafe path is never read") }
        XCTAssertEqual(CollectionArtworkSelector.presentation(entry: entry, mosaicEnabled: false, identity: mosaicA, epoch: 1, unusable: ["custom.jpg", "c.jpg"]), .single("a.jpg"))
    }

    // MARK: Presentation and accessibility

    func testReduceMotionRemovesTheTransition() {
        XCTAssertNil(CollectionArtworkCanvas.animation(reduceMotion: true))
        XCTAssertNotNil(CollectionArtworkCanvas.animation(reduceMotion: false))
        XCTAssertTrue((0.25...0.35).contains(CollectionArtworkCanvas.transitionDuration))
    }

    func testOnlyARealVisibleArtworkChangeCrossfades() {
        let first = CollectionArtworkPresentation.mosaic(CollectionMosaicSelection(tiles: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]))
        let next = CollectionArtworkPresentation.mosaic(CollectionMosaicSelection(tiles: ["a.jpg", "b.jpg", "c.jpg", "e.jpg"]))
        XCTAssertTrue(CollectionArtworkCanvas.shouldCrossfade(from: first, to: next, visible: true, reduceMotion: false))
        XCTAssertFalse(CollectionArtworkCanvas.shouldCrossfade(from: nil, to: next, visible: true, reduceMotion: false), "The first composition appears without animation")
        XCTAssertFalse(CollectionArtworkCanvas.shouldCrossfade(from: first, to: first, visible: true, reduceMotion: false), "A size or scale change of the same artwork swaps instantly")
        XCTAssertFalse(CollectionArtworkCanvas.shouldCrossfade(from: .placeholder, to: .placeholder, visible: true, reduceMotion: false))
        XCTAssertFalse(CollectionArtworkCanvas.shouldCrossfade(from: first, to: next, visible: false, reduceMotion: false), "Nothing animates off screen")
        XCTAssertFalse(CollectionArtworkCanvas.shouldCrossfade(from: first, to: next, visible: true, reduceMotion: true))
    }

    func testAccessibilityDescribesOneArtworkElement() {
        let mosaic = CollectionMosaicSelection(tiles: ["a.jpg", nil, nil, "b.jpg"])
        XCTAssertEqual(CollectionArtworkView.label(.mosaic(mosaic), title: "Road Trip"), "Automatic artwork for Road Trip")
        XCTAssertEqual(CollectionArtworkView.value(.mosaic(mosaic)), "2 song covers")
        XCTAssertEqual(CollectionArtworkView.label(.custom("c.jpg"), title: "Road Trip"), "Custom artwork for Road Trip")
        XCTAssertEqual(CollectionArtworkView.label(.placeholder, title: "Road Trip"), "Artwork for Road Trip")
        XCTAssertEqual(CollectionArtworkView.value(.placeholder), "No song covers")
    }

    func testUnassignedSongsIsAVirtualCollection() {
        XCTAssertEqual(CollectionArtworkIdentity.album(LibrarySnapshot.unassignedAlbumID).kind, .unassigned)
        XCTAssertEqual(CollectionArtworkIdentity.album("album-1").kind, .album)
        XCTAssertFalse(CollectionArtworkKind.unassigned.hasPersistentPreference)
        XCTAssertFalse(CollectionArtworkKind.artist.supportsCustomCover)
    }
}
