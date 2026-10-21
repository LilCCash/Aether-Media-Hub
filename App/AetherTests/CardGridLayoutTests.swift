import XCTest
import SwiftUI
import AetherCore
@testable import Aether

/// The columns and card width of the Discover / Library grids: three posters per row (two banners for "Continua a guardare")
/// and the same margin on both sides, on every iPhone width.
final class CardGridLayoutTests: XCTestCase {
    private typealias Grid = AdaptiveCardGrid<MetaItem, EmptyView>

    private let phoneWidths: [CGFloat] = [320, 375, 390, 393, 402, 414, 430, 440]

    func testPostersAreThreePerRowOnEveryPhone() {
        for width in phoneWidths {
            let metrics = Grid.layout(containerWidth: width, margin: 16, spacing: 12, minColumns: 3, preferredWidth: 130)
            XCTAssertEqual(metrics.columns, 3, "container \(width)")
        }
    }

    func testPostersLargerThanThePreferredWidthStillGiveThreeColumns() {
        for preferred in [128, 140, 160, 180] as [CGFloat] {
            let metrics = Grid.layout(containerWidth: 393, margin: 16, spacing: 12, minColumns: 3, preferredWidth: preferred)
            XCTAssertEqual(metrics.columns, 3, "preferred \(preferred)")
        }
    }

    func testContinueWatchingBannersAreAtLeastTwoPerRow() {
        for width in phoneWidths {
            let metrics = Grid.layout(containerWidth: width, margin: 16, spacing: 14, minColumns: 2, preferredWidth: 240)
            XCTAssertEqual(metrics.columns, 2, "container \(width)")
        }
    }

    func testTheCardsFillTheRowWithTheSameMarginOnBothSides() {
        for width in phoneWidths {
            for (minColumns, preferred, spacing) in [(3, 130, 12), (2, 240, 14)] as [(Int, CGFloat, CGFloat)] {
                let metrics = Grid.layout(containerWidth: width, margin: 16, spacing: spacing, minColumns: minColumns, preferredWidth: preferred)
                let rowWidth = CGFloat(metrics.columns) * metrics.cardWidth + CGFloat(metrics.columns - 1) * spacing
                let available = width - 32
                XCTAssertLessThanOrEqual(rowWidth, available, "the row must fit, container \(width)")
                // The cards are whole points, so what is left over is less than one point per column and is shared by both sides.
                XCTAssertLessThan(available - rowWidth, CGFloat(metrics.columns), "container \(width): spare room is not symmetric")
            }
        }
    }

    func testWideScreensAddColumnsInsteadOfStretchingTheCards() {
        let tablet = Grid.layout(containerWidth: 1024, margin: 16, spacing: 12, minColumns: 3, preferredWidth: 130)
        XCTAssertGreaterThan(tablet.columns, 3)
        XCTAssertLessThan(tablet.cardWidth, 160)
    }

    func testAnUnmeasuredOrTinyContainerNeverProducesANegativeWidth() {
        let metrics = Grid.layout(containerWidth: 0, margin: 16, spacing: 12, minColumns: 3, preferredWidth: 130)
        XCTAssertEqual(metrics.columns, 3)
        XCTAssertGreaterThanOrEqual(metrics.cardWidth, 40)
    }
}
