import CoreGraphics
import Foundation
import PDFKit

public struct PocketModSourceHint: Equatable, Sendable {
    public let isLandscape: Bool
    public let rotationCorrectionDegrees: Int
    public let sourceSize: CGSize?
    public let method: String
    public let debugDescription: String

    public init(
        isLandscape: Bool,
        rotationCorrectionDegrees: Int,
        sourceSize: CGSize?,
        method: String,
        debugDescription: String = ""
    ) {
        self.isLandscape = isLandscape
        self.rotationCorrectionDegrees = rotationCorrectionDegrees
        self.sourceSize = sourceSize
        self.method = method
        self.debugDescription = debugDescription
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

    func applying(to point: CGPoint) -> CGPoint {
        CGPoint(
            x: a * point.x + c * point.y + tx,
            y: b * point.x + d * point.y + ty
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

private struct SpoolCandidate {
    let sourceSize: CGSize
    let transform: PDFMatrix
    let coverage: CGFloat
    let kind: String

    var quarterTurn: Int? {
        transform.snappedQuarterTurn
    }

    func score(spoolSize: CGSize) -> CGFloat {
        var value = min(max(coverage, 0), 1.5)

        if quarterTurn == 90 || quarterTurn == 270 {
            value += 0.75
        }

        let sourceRatio = max(sourceSize.width, sourceSize.height) /
            max(min(sourceSize.width, sourceSize.height), 1)
        let spoolRatio = max(spoolSize.width, spoolSize.height) /
            max(min(spoolSize.width, spoolSize.height), 1)

        if abs(sourceRatio - spoolRatio) > 0.05 {
            value += 0.20
        }

        if kind == "form" {
            value += 0.10
        } else if kind == "clip" {
            value += 0.08
        }

        return value
    }
}

private final class SpoolScannerState {
    var ctm = PDFMatrix.identity
    var stack: [PDFMatrix] = []
    var lastRectangle: CGRect?
    var candidates: [SpoolCandidate] = []
    var contentTransforms: [PDFMatrix] = []
    var matrixEvents: [PDFMatrix] = []
    var textMatrix = PDFMatrix.identity
    let spoolSize: CGSize

    init(spoolSize: CGSize) {
        self.spoolSize = spoolSize
    }

    func addCandidate(sourceSize: CGSize, transform: PDFMatrix, kind: String) {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return }

        let corners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: sourceSize.width, y: 0),
            CGPoint(x: 0, y: sourceSize.height),
            CGPoint(x: sourceSize.width, y: sourceSize.height),
        ].map { transform.applying(to: $0) }

        guard
            let minX = corners.map(\.x).min(),
            let maxX = corners.map(\.x).max(),
            let minY = corners.map(\.y).min(),
            let maxY = corners.map(\.y).max()
        else {
            return
        }

        let transformedArea = max(0, maxX - minX) * max(0, maxY - minY)
        let spoolArea = max(spoolSize.width * spoolSize.height, 1)
        candidates.append(
            SpoolCandidate(
                sourceSize: sourceSize,
                transform: transform,
                coverage: transformedArea / spoolArea,
                kind: kind
            )
        )
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
    state.lastRectangle = nil
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
    state.matrixEvents.append(state.ctm)
}

private let beginTextCallback: CGPDFOperatorCallback = { _, info in
    guard let state = scannerState(info) else { return }
    state.textMatrix = .identity
}

private let textMatrixCallback: CGPDFOperatorCallback = { scanner, info in
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

    state.textMatrix = PDFMatrix(a: a, b: b, c: c, d: d, tx: e, ty: f)
    state.contentTransforms.append(state.ctm.followed(by: state.textMatrix))
}

private let showTextCallback: CGPDFOperatorCallback = { _, info in
    guard let state = scannerState(info) else { return }
    state.contentTransforms.append(state.ctm.followed(by: state.textMatrix))
}

private let paintPathCallback: CGPDFOperatorCallback = { _, info in
    guard let state = scannerState(info) else { return }
    state.contentTransforms.append(state.ctm)
}

private let rectangleCallback: CGPDFOperatorCallback = { scanner, info in
    guard
        let state = scannerState(info),
        let height = popNumber(scanner),
        let width = popNumber(scanner),
        let y = popNumber(scanner),
        let x = popNumber(scanner)
    else {
        return
    }

    state.lastRectangle = CGRect(x: x, y: y, width: width, height: height)
}

private let clipCallback: CGPDFOperatorCallback = { _, info in
    guard let state = scannerState(info), let rect = state.lastRectangle else { return }
    let size = CGSize(width: abs(rect.width), height: abs(rect.height))
    state.addCandidate(sourceSize: size, transform: state.ctm, kind: "clip")
}

private func pdfArrayRect(_ array: CGPDFArrayRef) -> CGRect? {
    guard CGPDFArrayGetCount(array) >= 4 else { return nil }
    var values = [CGPDFReal](repeating: 0, count: 4)

    for index in 0..<4 {
        guard CGPDFArrayGetNumber(array, index, &values[index]) else { return nil }
    }

    return CGRect(
        x: CGFloat(values[0]),
        y: CGFloat(values[1]),
        width: CGFloat(values[2] - values[0]),
        height: CGFloat(values[3] - values[1])
    )
}

private func pdfArrayMatrix(_ array: CGPDFArrayRef) -> PDFMatrix? {
    guard CGPDFArrayGetCount(array) >= 6 else { return nil }
    var values = [CGPDFReal](repeating: 0, count: 6)

    for index in 0..<6 {
        guard CGPDFArrayGetNumber(array, index, &values[index]) else { return nil }
    }

    return PDFMatrix(
        a: CGFloat(values[0]),
        b: CGFloat(values[1]),
        c: CGFloat(values[2]),
        d: CGFloat(values[3]),
        tx: CGFloat(values[4]),
        ty: CGFloat(values[5])
    )
}

private let drawXObjectCallback: CGPDFOperatorCallback = { scanner, info in
    guard let state = scannerState(info) else { return }

    var namePointer: UnsafePointer<CChar>?
    guard CGPDFScannerPopName(scanner, &namePointer), let namePointer else { return }

    let contentStream = CGPDFScannerGetContentStream(scanner)
    guard let object = CGPDFContentStreamGetResource(contentStream, "XObject", namePointer) else {
        return
    }

    var stream: CGPDFStreamRef?
    guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return }
    guard let dictionary = CGPDFStreamGetDictionary(stream) else { return }

    var subtypePointer: UnsafePointer<CChar>?
    guard
        CGPDFDictionaryGetName(dictionary, "Subtype", &subtypePointer),
        let subtypePointer
    else {
        return
    }

    let subtype = String(cString: subtypePointer)

    if subtype == "Image" {
        state.contentTransforms.append(state.ctm)

        var width: CGPDFInteger = 0
        var height: CGPDFInteger = 0
        if CGPDFDictionaryGetInteger(dictionary, "Width", &width),
           CGPDFDictionaryGetInteger(dictionary, "Height", &height),
           width > 0, height > 0 {
            state.addCandidate(
                sourceSize: CGSize(width: CGFloat(width), height: CGFloat(height)),
                transform: state.ctm,
                kind: "image"
            )
        }
        return
    }

    guard subtype == "Form" else { return }

    var bboxArray: CGPDFArrayRef?
    guard
        CGPDFDictionaryGetArray(dictionary, "BBox", &bboxArray),
        let bboxArray,
        let bbox = pdfArrayRect(bboxArray)
    else {
        return
    }

    var formMatrix = PDFMatrix.identity
    var matrixArray: CGPDFArrayRef?
    if
        CGPDFDictionaryGetArray(dictionary, "Matrix", &matrixArray),
        let matrixArray,
        let parsed = pdfArrayMatrix(matrixArray)
    {
        formMatrix = parsed
    }

    let combined = state.ctm.followed(by: formMatrix)
    state.contentTransforms.append(combined)
    state.addCandidate(
        sourceSize: CGSize(width: abs(bbox.width), height: abs(bbox.height)),
        transform: combined,
        kind: "form"
    )
}

public enum PocketModSpoolAnalyzer {
    public static func hint(for page: PDFPage) -> PocketModSourceHint {
        let fallbackLandscape = PocketModImposer.sourceIsLandscape(page: page)
        let fallback = PocketModSourceHint(
            isLandscape: fallbackLandscape,
            rotationCorrectionDegrees: 0,
            sourceSize: nil,
            method: "page-box",
            debugDescription: ""
        )

        guard let pageRef = page.pageRef else { return fallback }

        let spoolBounds = page.bounds(for: .cropBox)
        guard spoolBounds.width > 0, spoolBounds.height > 0 else { return fallback }

        let state = SpoolScannerState(spoolSize: spoolBounds.size)
        guard let table = CGPDFOperatorTableCreate() else { return fallback }

        CGPDFOperatorTableSetCallback(table, "q", saveStateCallback)
        CGPDFOperatorTableSetCallback(table, "Q", restoreStateCallback)
        CGPDFOperatorTableSetCallback(table, "cm", concatMatrixCallback)
        CGPDFOperatorTableSetCallback(table, "BT", beginTextCallback)
        CGPDFOperatorTableSetCallback(table, "Tm", textMatrixCallback)
        CGPDFOperatorTableSetCallback(table, "Tj", showTextCallback)
        CGPDFOperatorTableSetCallback(table, "TJ", showTextCallback)
        CGPDFOperatorTableSetCallback(table, "'", showTextCallback)
        CGPDFOperatorTableSetCallback(table, "\"", showTextCallback)
        CGPDFOperatorTableSetCallback(table, "S", paintPathCallback)
        CGPDFOperatorTableSetCallback(table, "s", paintPathCallback)
        CGPDFOperatorTableSetCallback(table, "f", paintPathCallback)
        CGPDFOperatorTableSetCallback(table, "F", paintPathCallback)
        CGPDFOperatorTableSetCallback(table, "f*", paintPathCallback)
        CGPDFOperatorTableSetCallback(table, "B", paintPathCallback)
        CGPDFOperatorTableSetCallback(table, "B*", paintPathCallback)
        CGPDFOperatorTableSetCallback(table, "b", paintPathCallback)
        CGPDFOperatorTableSetCallback(table, "b*", paintPathCallback)
        CGPDFOperatorTableSetCallback(table, "re", rectangleCallback)
        CGPDFOperatorTableSetCallback(table, "W", clipCallback)
        CGPDFOperatorTableSetCallback(table, "W*", clipCallback)
        CGPDFOperatorTableSetCallback(table, "Do", drawXObjectCallback)

        let contentStream = CGPDFContentStreamCreateWithPage(pageRef)
        let info = Unmanaged.passUnretained(state).toOpaque()
        let scanner = CGPDFScannerCreate(contentStream, table, info)

        let scanned = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(contentStream)
        CGPDFOperatorTableRelease(table)

        guard scanned, !state.candidates.isEmpty else { return fallback }

        let candidate = state.candidates.max {
            $0.score(spoolSize: spoolBounds.size) < $1.score(spoolSize: spoolBounds.size)
        }!

        let sourceSize = candidate.sourceSize

        let transformedContent = state.contentTransforms.filter {
            guard let turn = $0.snappedQuarterTurn else { return false }
            return turn == 90 || turn == 270
        }

        let strongestTurn = transformedContent.max {
            max($0.scaleX, $0.scaleY) < max($1.scaleX, $1.scaleY)
        }

        let turn = strongestTurn?.snappedQuarterTurn
        let scaleX = strongestTurn?.scaleX ?? 0
        let scaleY = strongestTurn?.scaleY ?? 0
        let uniformScale = max(scaleX, scaleY)

        // Preview's print pipeline uses a near-1.0 scale for Letter-sized
        // landscape pages rotated into the portrait spool. Much smaller
        // quarter-turn scales indicate an oversized source page such as a
        // large square being reduced to fit.
        let rotatedContent = turn == 90 || turn == 270
        let oversizedRotatedSource = rotatedContent && uniformScale > 0 && uniformScale < 0.80
        let isLandscape = rotatedContent && !oversizedRotatedSource

        var correction = 0
        if oversizedRotatedSource, let turn {
            correction = (360 - turn) % 360
        }

        let matrixSummary = state.matrixEvents.suffix(12).map {
            "a=\(String(format: "%.3f", $0.a)),b=\(String(format: "%.3f", $0.b))," +
            "c=\(String(format: "%.3f", $0.c)),d=\(String(format: "%.3f", $0.d))," +
            "sx=\(String(format: "%.3f", $0.scaleX)),sy=\(String(format: "%.3f", $0.scaleY))," +
            "turn=\($0.snappedQuarterTurn.map(String.init) ?? "nil")"
        }.joined(separator: " | ")

        let contentSummary = state.contentTransforms.suffix(12).map {
            "sx=\(String(format: "%.3f", $0.scaleX)),sy=\(String(format: "%.3f", $0.scaleY))," +
            "turn=\($0.snappedQuarterTurn.map(String.init) ?? "nil")"
        }.joined(separator: " | ")

        return PocketModSourceHint(
            isLandscape: isLandscape,
            rotationCorrectionDegrees: correction,
            sourceSize: sourceSize,
            method: rotatedContent ? "content-transform" : candidate.kind + "-content-stream",
            debugDescription:
                "selectedClip=\(Int(sourceSize.width))x\(Int(sourceSize.height)); " +
                "content=[\(contentSummary)]; matrices=[\(matrixSummary)]"
        )
    }
}
