import AppKit
import Foundation
import PocketModCore
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingJobs = 0
    private var receivedOpenEvent = false
    private var temporaryOutputs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        cleanupStaleTemporaryFiles()

        let arguments = Array(CommandLine.arguments.dropFirst())
        if let pdfPath = arguments.last, pdfPath.lowercased().hasSuffix(".pdf") {
            let includeGuides = arguments.contains("--guides")
            receivedOpenEvent = true
            process(urls: [URL(fileURLWithPath: pdfPath)], includeGuides: includeGuides)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if !self.receivedOpenEvent && self.pendingJobs == 0 {
                self.choosePDF()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeTemporaryOutputs()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        receivedOpenEvent = true
        sender.reply(toOpenOrPrint: .success)
        process(urls: filenames.map(URL.init(fileURLWithPath:)), includeGuides: false)
    }

    private func choosePDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK else {
                NSApp.terminate(nil)
                return
            }
            self.process(urls: panel.urls, includeGuides: false)
        }
    }

    private func process(urls: [URL], includeGuides: Bool) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else {
            showError(message: "No PDF was supplied.")
            NSApp.terminate(nil)
            return
        }

        pendingJobs += pdfs.count

        for inputURL in pdfs {
            do {
                let outputURL = makeTemporaryOutputURL(for: inputURL)
                try PocketModImposer.impose(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    includeGuides: includeGuides
                )
                temporaryOutputs.append(outputURL)

                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open(outputURL, configuration: configuration) { _, error in
                    if let error {
                        self.showError(message: error.localizedDescription)
                    }
                    self.finishedOne()
                }
            } catch {
                showError(message: error.localizedDescription)
                finishedOne()
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
            // LaunchServices can report that the viewer accepted the open request before
            // the viewer has actually read the file. Give it time to acquire the document,
            // then terminate; applicationWillTerminate removes our temporary pathname.
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
