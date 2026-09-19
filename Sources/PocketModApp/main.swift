import AppKit
import Foundation
import PDFKit
import PocketModCore

private struct SourcePageHints {
    let landscape: [Bool]
    let rotationCorrections: [Int]
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingJobs = 0
    private var receivedOpenEvent = false
    private var temporaryOutputs: [URL] = []
    private let includeGuidesForLaunch = CommandLine.arguments.contains("--guides")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        cleanupStaleTemporaryFiles()
        log("App launched args=\(CommandLine.arguments.joined(separator: " | "))")

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if !self.receivedOpenEvent && self.pendingJobs == 0 {
                self.log("No PDF open event arrived")
                self.showFatalError(
                    "No PDF was received from the Print dialog. The helper app launched, but macOS did not deliver the print PDF."
                )
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("App terminating")
        removeTemporaryOutputs()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        receivedOpenEvent = true
        log("Received openFiles: \(filenames.joined(separator: " | "))")
        sender.reply(toOpenOrPrint: .success)

        for filename in filenames {
            process(
                inputURL: URL(fileURLWithPath: filename),
                includeGuides: includeGuidesForLaunch
            )
        }
    }

    private func process(inputURL: URL, includeGuides: Bool) {
        guard inputURL.pathExtension.lowercased() == "pdf" else {
            log("Rejected non-PDF input: \(inputURL.path)")
            showFatalError("The Print service did not provide a PDF.")
            return
        }

        pendingJobs += 1
        log("Processing PDF: \(inputURL.path), guides=\(includeGuides)")
        let sourceHints = recoverSourceHintsFromPreview(spoolURL: inputURL)
        logPageDiagnostics(inputURL, sourceHints: sourceHints)

        do {
            let outputURL = makeTemporaryOutputURL(for: inputURL)
            try PocketModImposer.impose(
                inputURL: inputURL,
                outputURL: outputURL,
                includeGuides: includeGuides,
                landscapeHints: sourceHints?.landscape,
                sourceRotationCorrections: sourceHints?.rotationCorrections
            )
            temporaryOutputs.append(outputURL)
            log("Created PocketMod: \(outputURL.path)")

            let configuration = NSWorkspace.OpenConfiguration()

            if let previewURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.Preview"
            ) {
                NSWorkspace.shared.open(
                    [outputURL],
                    withApplicationAt: previewURL,
                    configuration: configuration
                ) { _, error in
                    if let error {
                        self.log("Preview open failed: \(error.localizedDescription)")
                        self.showError(error.localizedDescription)
                    } else {
                        self.log("Preview accepted PocketMod")
                    }
                    self.finishedOne()
                }
            } else {
                log("Preview app not found; using default PDF viewer")
                NSWorkspace.shared.open(outputURL, configuration: configuration) { _, error in
                    if let error {
                        self.log("Default viewer open failed: \(error.localizedDescription)")
                        self.showError(error.localizedDescription)
                    } else {
                        self.log("Default viewer accepted PocketMod")
                    }
                    self.finishedOne()
                }
            }
        } catch {
            log("Imposition failed: \(error.localizedDescription)")
            showError(error.localizedDescription)
            finishedOne()
        }
    }

    private func logPageDiagnostics(_ inputURL: URL, sourceHints: SourcePageHints?) {
        guard let document = PDFDocument(url: inputURL) else {
            log("Could not inspect PDF for diagnostics")
            return
        }

        for basePage in stride(from: 0, to: document.pageCount, by: 8) {
            for placement in PocketModLayout.placements(
                startingAt: basePage,
                pageCount: document.pageCount
            ) {
                guard let pageIndex = placement.pageIndex,
                      let page = document.page(at: pageIndex) else {
                    continue
                }

                let kit = page.bounds(for: .cropBox)
                let raw = page.pageRef?.getBoxRect(.cropBox) ?? kit
                let rawRotation = page.pageRef.map { Int($0.rotationAngle) } ?? page.rotation
                let spoolLandscape = PocketModImposer.sourceIsLandscape(page: page)
                let sourceHint = sourceHints.flatMap {
                    pageIndex < $0.landscape.count ? $0.landscape[pageIndex] : nil
                }
                let rotationCorrection = sourceHints.flatMap {
                    pageIndex < $0.rotationCorrections.count ? $0.rotationCorrections[pageIndex] : nil
                } ?? 0
                let effectiveLandscape = sourceHint ?? spoolLandscape
                let extra = PocketModImposer.extraRotationDegrees(
                    pageIndex: pageIndex,
                    isLandscape: effectiveLandscape
                )
                let total = PocketModImposer.totalRotationDegrees(
                    pageIndex: pageIndex,
                    placementRotationDegrees: placement.rotationDegrees,
                    isLandscape: effectiveLandscape,
                    sourceRotationCorrectionDegrees: rotationCorrection
                )

                log(
                    "page=\(pageIndex + 1) kit=\(Int(kit.width))x\(Int(kit.height)) " +
                    "raw=\(Int(raw.width))x\(Int(raw.height)) rawRotation=\(rawRotation) " +
                    "spoolLandscape=\(spoolLandscape) sourceHint=\(String(describing: sourceHint)) " +
                    "effectiveLandscape=\(effectiveLandscape) panelRotation=\(placement.rotationDegrees) " +
                    "extraRotation=\(extra) sourceCorrection=\(rotationCorrection) totalRotation=\(total)"
                )
            }
        }
    }

    private func recoverSourceHintsFromPreview(spoolURL: URL) -> SourcePageHints? {
        guard let spoolDocument = PDFDocument(url: spoolURL) else {
            log("Could not open spool PDF while looking for source orientation hints")
            return nil
        }

        let spoolStem = normalizedPDFStem(spoolURL.lastPathComponent)
        var candidates: [(url: URL, score: Int)] = []

        for app in NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.Preview"
        ) {
            for url in openPDFs(forProcessIdentifier: app.processIdentifier) {
                let path = url.path
                if path.contains("com.apple.printtool.agent") ||
                    path.contains("/PrintAsPocketMod-") ||
                    path.contains("/PrintAsPocketMod.") {
                    continue
                }

                guard let document = PDFDocument(url: url),
                      document.pageCount == spoolDocument.pageCount else {
                    continue
                }

                let candidateStem = normalizedPDFStem(url.lastPathComponent)
                var score = 1

                if candidateStem == spoolStem {
                    score += 100
                } else if spoolStem.contains(candidateStem) || candidateStem.contains(spoolStem) {
                    score += 25
                }

                candidates.append((url, score))
            }
        }

        guard let best = candidates.max(by: { $0.score < $1.score }),
              best.score > 1 || candidates.count == 1,
              let sourceDocument = PDFDocument(url: best.url) else {
            log("No matching original PDF found in Preview; using print-spool geometry")
            return nil
        }

        guard let referencePage = sourceDocument.page(at: 0) else {
            log("Original PDF has no first page for source-size comparison")
            return nil
        }

        let referenceBounds = referencePage.bounds(for: .cropBox)
        let referenceLongSide = max(referenceBounds.width, referenceBounds.height)

        var landscape: [Bool] = []
        var rotationCorrections: [Int] = []
        var oversizedSquarePages: [String] = []

        for index in 0..<sourceDocument.pageCount {
            guard let page = sourceDocument.page(at: index) else {
                landscape.append(false)
                rotationCorrections.append(0)
                continue
            }

            let bounds = page.bounds(for: .cropBox)
            let longSide = max(bounds.width, bounds.height)
            let shortSide = min(bounds.width, bounds.height)
            let isSquare = longSide > 0 && abs(longSide - shortSide) / longSide < 0.01
            let isOversizedSquare = isSquare && longSide > referenceLongSide * 1.05

            landscape.append(PocketModImposer.sourceIsLandscape(page: page))

            // Preview's Print dialog quarter-turns oversized square pages while
            // fitting them to a portrait spool page. Fold testing establishes
            // the required counter-turn direction for the resulting spool page.
            if isOversizedSquare {
                rotationCorrections.append(90)
                oversizedSquarePages.append(String(index + 1))
            } else {
                rotationCorrections.append(0)
            }
        }

        log(
            "Recovered source orientation from Preview: \(best.url.path) " +
            "landscapePages=\(landscape.enumerated().compactMap { $0.element ? String($0.offset + 1) : nil }.joined(separator: ",")) " +
            "oversizedSquarePages=\(oversizedSquarePages.joined(separator: ","))"
        )
        return SourcePageHints(
            landscape: landscape,
            rotationCorrections: rotationCorrections
        )
    }

    private func openPDFs(forProcessIdentifier processIdentifier: pid_t) -> [URL] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-Fn", "-p", String(processIdentifier)]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log("Could not run lsof for Preview: \(error.localizedDescription)")
            return []
        }

        guard process.terminationStatus == 0 else {
            log("lsof for Preview exited with status \(process.terminationStatus)")
            return []
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var seen = Set<String>()
        return text
            .split(separator: "\n")
            .compactMap { line -> URL? in
                guard line.first == "n" else { return nil }
                let path = String(line.dropFirst())
                guard path.hasPrefix("/"),
                      path.lowercased().hasSuffix(".pdf"),
                      FileManager.default.fileExists(atPath: path),
                      seen.insert(path).inserted else {
                    return nil
                }
                return URL(fileURLWithPath: path)
            }
    }

    private func normalizedPDFStem(_ filename: String) -> String {
        var name = filename.lowercased()
        while name.hasSuffix(".pdf") {
            name.removeLast(4)
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeTemporaryOutputURL(for inputURL: URL) -> URL {
        let stem = inputURL.deletingPathExtension().lastPathComponent
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("PrintAsPocketMod-\(UUID().uuidString)-\(stem)-PocketMod.pdf")
    }

    private func cleanupStaleTemporaryFiles() {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-3600)
        for url in entries where url.lastPathComponent.hasPrefix("PrintAsPocketMod-") {
            guard
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                let modified = values.contentModificationDate,
                modified < cutoff
            else { continue }
            try? manager.removeItem(at: url)
        }
    }

    private func finishedOne() {
        pendingJobs -= 1
        if pendingJobs <= 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                NSApp.terminate(nil)
            }
        }
    }

    private func removeTemporaryOutputs() {
        for url in temporaryOutputs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryOutputs.removeAll()
    }

    private func showError(_ message: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Print as PocketMod"
            alert.informativeText = message
            alert.runModal()
        }
    }

    private func showFatalError(_ message: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Print as PocketMod"
            alert.informativeText = message
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    private func log(_ message: String) {
        let manager = FileManager.default
        guard let logs = try? manager.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Logs", isDirectory: true) else {
            return
        }

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
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
