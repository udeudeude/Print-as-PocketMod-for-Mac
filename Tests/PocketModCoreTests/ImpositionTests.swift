import XCTest
@testable import PocketModCore

final class ImpositionTests: XCTestCase {
    func testStandardPocketModOrderAndRotation() {
        let placements = PocketModLayout.placements(startingAt: 0, pageCount: 8)

        XCTAssertEqual(placements.map(\.pageIndex), [0, 7, 6, 5, 1, 2, 3, 4])
        XCTAssertEqual(placements.map(\.rotationDegrees), [180, 180, 180, 180, 0, 0, 0, 0])
        XCTAssertEqual(placements.map(\.column), [0, 1, 2, 3, 0, 1, 2, 3])
        XCTAssertEqual(placements.map(\.row), [0, 0, 0, 0, 1, 1, 1, 1])
    }

    func testIncompleteFinalSheetUsesBlankPanels() {
        let placements = PocketModLayout.placements(startingAt: 8, pageCount: 11)

        XCTAssertEqual(placements[0].pageIndex, 8)
        XCTAssertNil(placements[1].pageIndex)
        XCTAssertNil(placements[2].pageIndex)
        XCTAssertNil(placements[3].pageIndex)
        XCTAssertEqual(placements[4].pageIndex, 9)
        XCTAssertEqual(placements[5].pageIndex, 10)
        XCTAssertNil(placements[6].pageIndex)
        XCTAssertNil(placements[7].pageIndex)
    }

    func testOddNumberedLandscapePagesGetAnExtraHalfTurn() {
        XCTAssertEqual(
            PocketModImposer.extraRotationDegrees(pageIndex: 8, isLandscape: true),
            180
        )
        XCTAssertEqual(
            PocketModImposer.extraRotationDegrees(pageIndex: 9, isLandscape: true),
            0
        )
        XCTAssertEqual(
            PocketModImposer.extraRotationDegrees(pageIndex: 10, isLandscape: true),
            180
        )
        XCTAssertEqual(
            PocketModImposer.extraRotationDegrees(pageIndex: 8, isLandscape: false),
            0
        )
    }

    func testSourceQuarterTurnCorrectionCombinesWithPanelRotation() {
        XCTAssertEqual(
            PocketModImposer.totalRotationDegrees(
                pageIndex: 6,
                placementRotationDegrees: 180,
                isLandscape: false,
                sourceRotationCorrectionDegrees: 270
            ),
            90
        )
    }

    func testSheetCount() {
        XCTAssertEqual(PocketModLayout.sheetCount(for: 0), 0)
        XCTAssertEqual(PocketModLayout.sheetCount(for: 1), 1)
        XCTAssertEqual(PocketModLayout.sheetCount(for: 8), 1)
        XCTAssertEqual(PocketModLayout.sheetCount(for: 9), 2)
        XCTAssertEqual(PocketModLayout.sheetCount(for: 16), 2)
        XCTAssertEqual(PocketModLayout.sheetCount(for: 17), 3)
    }
}
