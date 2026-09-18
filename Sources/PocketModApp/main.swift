import AppKit
import Foundation
import PocketModCore
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingJobs = 0
    private var receivedOpenEvent = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if !self.receivedOpenEvent && self.pendingJobs == 0 {
                self.choosePDF()
            }
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        receivedOpenEvent = true
        sender.reply(toOpenOrPrint: .success)
        process(urls: filenames.map(URL.init(fileURLWithPath:)))
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
            self.process(urls: panel.urls)
        }
    }

    private func process(urls: [URL]) {
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
                try PocketModImposer.impose(inputURL: inputURL, outputURL: outputURL)

                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open(outputURL, configuration: configuration) { _, error in
                    if let error {
                        self.showError(message: error.localizedDescription)
                    } else {
                        // Preview (or another PDF viewer) has opened the document. Remove our
                        // temporary directory entry immediately. The viewer can still display
                        // and print the already-open document; saving is an explicit user action.
                        try? FileManager.default.removeItem(at: outputURL)
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
            .appendingPathComponent("\(UUID().uuidString)-\(stem)-PocketMod.pdf")
    }

    private func finishedOne() {
        pendingJobs -= 1
        if pendingJobs <= 0 {
            NSApp.terminate(nil)
        }
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
