import AppKit
import Foundation
import PDFKit
import PocketModCore

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
        logPageDiagnostics(inputURL)

        do {
            let outputURL = makeTemporaryOutputURL(for: inputURL)
            try PocketModImposer.impose(
                inputURL: inputURL,
                outputURL: outputURL,
                includeGuides: includeGuides
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

    private func logPageDiagnostics(_ inputURL: URL) {
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
