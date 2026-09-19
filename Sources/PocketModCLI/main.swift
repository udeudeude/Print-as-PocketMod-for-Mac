import Foundation
import PDFKit
import PocketModCore

private func log(_ message: String) {
    let manager = FileManager.default
    let logs = manager.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs", isDirectory: true)
    try? manager.createDirectory(at: logs, withIntermediateDirectories: true)

    let url = logs.appendingPathComponent("Print-as-PocketMod.log")
    let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
    guard let data = line.data(using: .utf8) else { return }

    if manager.fileExists(atPath: url.path),
       let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url)
    }
}

private func fail(_ message: String) -> Never {
    log("ERROR: \(message)")
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    fail("Usage: PocketModCLI INPUT.pdf OUTPUT.pdf [--guides]")
}

let inputURL = URL(fileURLWithPath: arguments[0])
let outputURL = URL(fileURLWithPath: arguments[1])
let includeGuides = arguments.contains("--guides")
let started = Date()

log("CLI start input=\(inputURL.path) output=\(outputURL.path) guides=\(includeGuides)")

guard let document = PDFDocument(url: inputURL) else {
    fail("Could not inspect input PDF")
}

for basePage in stride(from: 0, to: document.pageCount, by: 8) {
    for placement in PocketModLayout.placements(startingAt: basePage, pageCount: document.pageCount) {
        guard let pageIndex = placement.pageIndex,
              let page = document.page(at: pageIndex) else { continue }

        let kit = page.bounds(for: .cropBox)
        let raw = page.pageRef?.getBoxRect(.cropBox) ?? kit
        let rawRotation = page.pageRef.map { Int($0.rotationAngle) } ?? page.rotation
        let landscape = PocketModImposer.sourceIsLandscape(page: page)
        let extra = PocketModImposer.extraRotationDegrees(
            pageIndex: pageIndex,
            isLandscape: landscape
        )
        let total = PocketModImposer.totalRotationDegrees(
            pageIndex: pageIndex,
            placementRotationDegrees: placement.rotationDegrees,
            isLandscape: landscape
        )

        log(
            "page=\(pageIndex + 1) kit=\(Int(kit.width))x\(Int(kit.height)) " +
            "raw=\(Int(raw.width))x\(Int(raw.height)) rawRotation=\(rawRotation) " +
            "landscape=\(landscape) panelRotation=\(placement.rotationDegrees) " +
            "extraRotation=\(extra) totalRotation=\(total)"
        )
    }
}

do {
    try PocketModImposer.impose(
        inputURL: inputURL,
        outputURL: outputURL,
        includeGuides: includeGuides
    )
    log("CLI finished in \(String(format: "%.3f", Date().timeIntervalSince(started)))s")
} catch {
    fail(error.localizedDescription)
}
