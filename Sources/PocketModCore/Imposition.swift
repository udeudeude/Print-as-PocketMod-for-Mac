import CoreGraphics
import Foundation
import PDFKit

public enum PocketModError: LocalizedError {
    case unreadablePDF(URL)
    case emptyPDF
    case cannotCreateOutput(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadablePDF(let url):
            return "Could not open PDF: \(url.path)"
        case .emptyPDF:
            return "The PDF has no pages."
        case .cannotCreateOutput(let url):
            return "Could not create PocketMod PDF: \(url.path)"
        }
    }
}

public struct PocketModPlacement: Equatable, Sendable {
    public let pageIndex: Int?
    public let column: Int
    public let row: Int
    public let rotationDegrees: Int

    public init(pageIndex: Int?, column: Int, row: Int, rotationDegrees: Int) {
        self.pageIndex = pageIndex
        self.column = column
        self.row = row
        self.rotationDegrees = rotationDegrees
    }
}

public enum PocketModLayout {
    public static let sourceOrder = [0, 7, 6, 5, 1, 2, 3, 4]

    public static func placements(startingAt basePage: Int, pageCount: Int) -> [PocketModPlacement] {
        sourceOrder.enumerated().map { slot, relativePage in
            let absolutePage = basePage + relativePage
            return PocketModPlacement(
                pageIndex: absolutePage < pageCount ? absolutePage : nil,
                column: slot % 4,
                row: slot / 4,
                rotationDegrees: slot < 4 ? 180 : 0
            )
        }
    }

    public static func sheetCount(for pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return (pageCount + 7) / 8
    }
}

public enum PocketModImposer {
    public static func extraRotationDegrees(pageIndex: Int, pageBounds: CGRect) -> Int {
        let isOddNumberedPage = pageIndex.isMultiple(of: 2)
        let isLandscape = pageBounds.width > pageBounds.height
        return isOddNumberedPage && isLandscape ? 180 : 0
    }

    public static func impose(inputURL: URL, outputURL: URL) throws {
        guard let document = PDFDocument(url: inputURL) else {
            throw PocketModError.unreadablePDF(inputURL)
        }
        guard document.pageCount > 0, let firstPage = document.page(at: 0) else {
            throw PocketModError.emptyPDF
        }

        let firstBounds = firstPage.bounds(for: .cropBox)
        let sheetWidth = max(firstBounds.width, firstBounds.height)
        let sheetHeight = min(firstBounds.width, firstBounds.height)
        var mediaBox = CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight)

        guard let consumer = CGDataConsumer(url: outputURL as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PocketModError.cannotCreateOutput(outputURL)
        }

        for basePage in stride(from: 0, to: document.pageCount, by: 8) {
            context.beginPDFPage(nil)

            for placement in PocketModLayout.placements(
                startingAt: basePage,
                pageCount: document.pageCount
            ) {
                guard let pageIndex = placement.pageIndex,
                      let page = document.page(at: pageIndex) else {
                    continue
                }

                draw(
                    page: page,
                    pageIndex: pageIndex,
                    placement: placement,
                    in: context,
                    sheetSize: mediaBox.size
                )
            }

            context.endPDFPage()
        }

        context.closePDF()
    }

    private static func draw(
        page: PDFPage,
        pageIndex: Int,
        placement: PocketModPlacement,
        in context: CGContext,
        sheetSize: CGSize
    ) {
        let cellWidth = sheetSize.width / 4
        let cellHeight = sheetSize.height / 2
        let cellX = CGFloat(placement.column) * cellWidth
        let cellY = placement.row == 0 ? cellHeight : 0
        let cell = CGRect(x: cellX, y: cellY, width: cellWidth, height: cellHeight)

        let pageBounds = page.bounds(for: .cropBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else { return }

        let scale = min(cell.width / pageBounds.width, cell.height / pageBounds.height)
        let drawnSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
        let origin = CGPoint(
            x: cell.minX + (cell.width - drawnSize.width) / 2,
            y: cell.minY + (cell.height - drawnSize.height) / 2
        )

        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)

        let totalRotation = (
            placement.rotationDegrees
            + extraRotationDegrees(pageIndex: pageIndex, pageBounds: pageBounds)
        ) % 360

        if totalRotation == 180 {
            context.translateBy(x: drawnSize.width / 2, y: drawnSize.height / 2)
            context.rotate(by: .pi)
            context.translateBy(x: -drawnSize.width / 2, y: -drawnSize.height / 2)
        }

        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
        page.draw(with: .cropBox, to: context)
        context.restoreGState()
    }
}
