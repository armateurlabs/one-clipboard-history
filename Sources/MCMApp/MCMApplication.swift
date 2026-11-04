import AppKit
import MCMCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            let demo = ProcessInfo.processInfo.arguments.contains("--demo")
                || Bundle.main.object(forInfoDictionaryKey: "MCMPreviewMode") as? Bool == true
            let controller = try AppController(demo: demo)
            self.controller = controller
            controller.start()
            if ProcessInfo.processInfo.arguments.contains("--show-window"),
               !ProcessInfo.processInfo.arguments.contains("--demo") { controller.show() }
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.text("mcm could not start")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) { controller?.stop() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { @MainActor in
            await controller.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.show()
        return true
    }
}

@main
struct MCMApplication {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
