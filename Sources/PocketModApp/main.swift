import AppKit
import Foundation
import PocketModCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingJobs = 0
    private var receivedOpenEvent = false
    private var temporaryOutputs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        cleanupStaleTemporaryFiles()

        // A Print-dialog PDF Service launches this app by opening the spool PDF with it.
        // Give LaunchServices a moment to deliver that open-file event. If no file arrives,
        // fail visibly rather than presenting an unexplained Finder file chooser.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if !self.receivedOpenEvent && self.pendingJobs == 0 {
                self.showError(
                    message: "No PDF was received from the Print dialog. Reinstall Print as PocketMod and try again."
                )
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeTemporaryOutputs()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        receivedOpenEvent = true
        sender.reply(toOpenOrPrint: .success)

        for filename in filenames {
            let inputURL = URL(fileURLWithPath: filename)
            let includeGuides = isGuidedInput(inputURL)
            process(inputURL: inputURL, includeGuides: includeGuides)
        }
    }

    private func process(inputURL: URL, includeGuides: Bool) {
        guard inputURL.pathExtension.lowercased() == "pdf" else {
            showError(message: "The Print service did not provide a PDF.")
            return
        }

        pendingJobs += 1

        do {
            let outputURL = makeTemporaryOutputURL(for: inputURL)
            try PocketModImposer.impose(
                inputURL: inputURL,
                outputURL: outputURL,
                includeGuides: includeGuides
            )
            temporaryOutputs.append(outputURL)
            removeGuidedInputIfNeeded(inputURL)

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
                        self.showError(message: error.localizedDescription)
                    }
                    self.finishedOne()
                }
            } else {
                NSWorkspace.shared.open(outputURL, configuration: configuration) { _, error in
                    if let error {
                        self.showError(message: error.localizedDescription)
                    }
                    self.finishedOne()
                }
            }
        } catch {
            removeGuidedInputIfNeeded(inputURL)
            showError(message: error.localizedDescription)
            finishedOne()
        }
    }

    private func isGuidedInput(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent.hasPrefix("PrintAsPocketModGuides.")
    }

    private func removeGuidedInputIfNeeded(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        guard directory.lastPathComponent.hasPrefix("PrintAsPocketModGuides.") else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
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
            // Preview may accept the open request before it has fully read the file.
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

    private func showError(message: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Print as PocketMod"
            alert.informativeText = message
            alert.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
