import AppKit
import Foundation
import PocketModCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingJobs = 0
    private var receivedOpenEvent = false
    private var temporaryOutputs: [URL] = []
    private var terminationWorkItem: DispatchWorkItem?

    private let includeGuidesForLaunch = CommandLine.arguments.contains("--guides")
    private let logFormatter = ISO8601DateFormatter()

    private lazy var outputDirectory: URL = {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PrintAsPocketMod", isDirectory: true)
    }()

    private lazy var logURL: URL? = {
        let manager = FileManager.default
        guard let library = try? manager.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }

        let logs = library.appendingPathComponent("Logs", isDirectory: true)
        try? manager.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("Print-as-PocketMod.log")
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        try? FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        cleanupStaleTemporaryFiles()

        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
        log(
            "App launched version=\(version) build=\(build) " +
            "args=\(CommandLine.arguments.joined(separator: " | "))"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if !self.receivedOpenEvent && self.pendingJobs == 0 {
                self.log("No PDF open event arrived")
                self.showFatalError(
                    "No PDF was received from the Print dialog. " +
                    "The helper app launched, but macOS did not deliver the print PDF."
                )
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminationWorkItem?.cancel()
        log("App terminating")
        removeTemporaryOutputs()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        receivedOpenEvent = true
        terminationWorkItem?.cancel()
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

        terminationWorkItem?.cancel()
        pendingJobs += 1
        log("Processing PDF: \(inputURL.path), guides=\(includeGuides)")

        do {
            let outputURL = makeTemporaryOutputURL(for: inputURL)
            try PocketModImposer.impose(
                inputURL: inputURL,
                outputURL: outputURL,
                includeGuides: includeGuides
            )
            temporaryOutputs.append(outputURL)
            log("Created PocketMod: \(outputURL.path)")
            openOutput(outputURL)
        } catch {
            log("Imposition failed: \(error.localizedDescription)")
            showError(error.localizedDescription) {
                self.finishOne()
            }
        }
    }

    private func openOutput(_ outputURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()

        if let previewURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Preview"
        ) {
            NSWorkspace.shared.open(
                [outputURL],
                withApplicationAt: previewURL,
                configuration: configuration
            ) { _, error in
                self.handleViewerResult(error, viewerName: "Preview")
            }
        } else {
            log("Preview app not found; using default PDF viewer")
            NSWorkspace.shared.open(
                outputURL,
                configuration: configuration
            ) { _, error in
                self.handleViewerResult(error, viewerName: "Default viewer")
            }
        }
    }

    private func handleViewerResult(_ error: Error?, viewerName: String) {
        DispatchQueue.main.async {
            if let error {
                self.log("\(viewerName) open failed: \(error.localizedDescription)")
                self.showError(error.localizedDescription) {
                    self.finishOne()
                }
            } else {
                self.log("\(viewerName) accepted PocketMod")
                self.finishOne()
            }
        }
    }

    private func makeTemporaryOutputURL(for inputURL: URL) -> URL {
        let stem = inputURL.deletingPathExtension().lastPathComponent
        return outputDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(stem)-PocketMod.pdf")
    }

    private func cleanupStaleTemporaryFiles() {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-3600)
        for url in entries {
            guard
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                let modified = values.contentModificationDate,
                modified < cutoff
            else {
                continue
            }
            try? manager.removeItem(at: url)
        }
    }

    private func finishOne() {
        precondition(Thread.isMainThread)

        pendingJobs = max(0, pendingJobs - 1)
        guard pendingJobs == 0 else {
            return
        }

        terminationWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            NSApp.terminate(nil)
        }
        terminationWorkItem = workItem

        // Preview has already accepted the file. Keep the existing grace period
        // so it can finish any lazy reads before termination removes the temp PDF.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: workItem)
    }

    private func removeTemporaryOutputs() {
        for url in temporaryOutputs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryOutputs.removeAll()
    }

    private func showError(_ message: String, completion: @escaping () -> Void) {
        let present = {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Print as PocketMod"
            alert.informativeText = message
            alert.runModal()
            completion()
        }

        if Thread.isMainThread {
            present()
        } else {
            DispatchQueue.main.async(execute: present)
        }
    }

    private func showFatalError(_ message: String) {
        let present = {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Print as PocketMod"
            alert.informativeText = message
            alert.runModal()
            NSApp.terminate(nil)
        }

        if Thread.isMainThread {
            present()
        } else {
            DispatchQueue.main.async(execute: present)
        }
    }

    private func log(_ message: String) {
        guard let url = logURL else {
            return
        }

        let line = "\(logFormatter.string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }

        let manager = FileManager.default
        if manager.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
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
