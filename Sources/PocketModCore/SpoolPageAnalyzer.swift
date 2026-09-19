import CoreGraphics
import PDFKit

struct PocketModSourceHint: Equatable {
    let isLandscape: Bool
    let rotationCorrectionDegrees: Int

    init(isLandscape: Bool, rotationCorrectionDegrees: Int) {
        self.isLandscape = isLandscape
        self.rotationCorrectionDegrees = rotationCorrectionDegrees
    }
}

private struct PDFMatrix {
    var a: CGFloat
    var b: CGFloat
    var c: CGFloat
    var d: CGFloat
    var tx: CGFloat
    var ty: CGFloat

    static let identity = PDFMatrix(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    func followed(by next: PDFMatrix) -> PDFMatrix {
        PDFMatrix(
            a: next.a * a + next.c * b,
            b: next.b * a + next.d * b,
            c: next.a * c + next.c * d,
            d: next.b * c + next.d * d,
            tx: next.a * tx + next.c * ty + next.tx,
            ty: next.b * tx + next.d * ty + next.ty
        )
    }

    var scaleX: CGFloat {
        hypot(a, b)
    }

    var scaleY: CGFloat {
        hypot(c, d)
    }

    var snappedQuarterTurn: Int? {
        let degrees = atan2(b, a) * 180 / .pi
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let candidates = [0, 90, 180, 270]
        guard let closest = candidates.min(by: {
            angularDistance(normalized, CGFloat($0)) < angularDistance(normalized, CGFloat($1))
        }) else {
            return nil
        }
        return angularDistance(normalized, CGFloat(closest)) <= 8 ? closest : nil
    }
}

private func angularDistance(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
    let difference = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
    return min(difference, 360 - difference)
}

private final class SpoolScannerState {
    var ctm = PDFMatrix.identity
    var stack: [PDFMatrix] = []
    var bestQuarterTurn: Int?
    var bestQuarterTurnScale: CGFloat = 0

    func recordCurrentTransform() {
        guard let turn = ctm.snappedQuarterTurn,
              turn == 90 || turn == 270 else {
            return
        }

        let scale = max(ctm.scaleX, ctm.scaleY)
        if scale > bestQuarterTurnScale {
            bestQuarterTurn = turn
            bestQuarterTurnScale = scale
        }
    }
}

private func scannerState(_ info: UnsafeMutableRawPointer?) -> SpoolScannerState? {
    guard let info else { return nil }
    return Unmanaged<SpoolScannerState>.fromOpaque(info).takeUnretainedValue()
}

private func popNumber(_ scanner: CGPDFScannerRef) -> CGFloat? {
    var value: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
    return CGFloat(value)
}

private let saveStateCallback: CGPDFOperatorCallback = { _, info in
    guard let state = scannerState(info) else { return }
    state.stack.append(state.ctm)
}

private let restoreStateCallback: CGPDFOperatorCallback = { _, info in
    guard let state = scannerState(info), let previous = state.stack.popLast() else { return }
    state.ctm = previous
}

private let concatMatrixCallback: CGPDFOperatorCallback = { scanner, info in
    guard
        let state = scannerState(info),
        let f = popNumber(scanner),
        let e = popNumber(scanner),
        let d = popNumber(scanner),
        let c = popNumber(scanner),
        let b = popNumber(scanner),
        let a = popNumber(scanner)
    else {
        return
    }

    let matrix = PDFMatrix(a: a, b: b, c: c, d: d, tx: e, ty: f)
    state.ctm = state.ctm.followed(by: matrix)
    state.recordCurrentTransform()
}

enum PocketModSpoolAnalyzer {
    static func hintForPageTransform(
        rotationDegrees: Int?,
        scale: CGFloat,
        fallbackLandscape: Bool = false
    ) -> PocketModSourceHint {
        guard let rotationDegrees,
              rotationDegrees == 90 || rotationDegrees == 270 else {
            return PocketModSourceHint(
                isLandscape: fallbackLandscape,
                rotationCorrectionDegrees: 0
            )
        }

        // Preview rotates ordinary landscape pages into the portrait print spool
        // at almost full size. Oversized square pages are also quarter-turned,
        // but are reduced much more aggressively. The observed transforms are
        // about 0.96 for landscape Letter pages and 0.58 for the oversized
        // square test page, so 0.80 leaves a broad gap between the two cases.
        let oversizedRotatedSource = scale > 0 && scale < 0.80
        return PocketModSourceHint(
            isLandscape: !oversizedRotatedSource,
            rotationCorrectionDegrees: oversizedRotatedSource
                ? (360 - rotationDegrees) % 360
                : 0
        )
    }

    static func hint(for page: PDFPage) -> PocketModSourceHint {
        let fallbackLandscape = PocketModImposer.sourceIsLandscape(page: page)
        let fallback = PocketModSourceHint(
            isLandscape: fallbackLandscape,
            rotationCorrectionDegrees: 0
        )

        guard let pageRef = page.pageRef else { return fallback }

        let state = SpoolScannerState()
        guard let table = CGPDFOperatorTableCreate() else { return fallback }

        CGPDFOperatorTableSetCallback(table, "q", saveStateCallback)
        CGPDFOperatorTableSetCallback(table, "Q", restoreStateCallback)
        CGPDFOperatorTableSetCallback(table, "cm", concatMatrixCallback)

        let contentStream = CGPDFContentStreamCreateWithPage(pageRef)
        let info = Unmanaged.passUnretained(state).toOpaque()
        let scanner = CGPDFScannerCreate(contentStream, table, info)

        let scanned = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(contentStream)
        CGPDFOperatorTableRelease(table)

        guard scanned else { return fallback }

        guard let rotationDegrees = state.bestQuarterTurn else {
            return fallback
        }

        return hintForPageTransform(
            rotationDegrees: rotationDegrees,
            scale: state.bestQuarterTurnScale,
            fallbackLandscape: fallbackLandscape
        )
    }
}
