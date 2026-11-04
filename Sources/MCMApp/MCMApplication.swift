import AppKit
import MCMCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?
    private var terminationPending = false
    private var startupError: (any Error)?
    private var failureStatusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            let demo = ProcessInfo.processInfo.arguments.contains("--demo")
                || Bundle.main.object(forInfoDictionaryKey: "MCMPreviewMode") as? Bool == true
            let controller = try AppController(demo: demo)
            self.controller = controller
            controller.start()
            if ProcessInfo.processInfo.arguments.contains("--show-window"),
               !ProcessInfo.processInfo.arguments.contains("--demo"),
               !AppLaunchContext.isBackgroundLaunchEvent(NSAppleEventManager.shared().currentAppleEvent) { controller.show() }
        } catch {
            // A login launch must not activate the app or present a modal alert.
            // Keep failure details available through an explicit menu action.
            startupError = error
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: L10n.text("mcm could not start"))
            let menu = NSMenu()
            menu.addItem(withTitle: L10n.text("mcm could not start"), action: #selector(showStartupError), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: L10n.text("Quit mcm"), action: #selector(quit), keyEquivalent: "q").target = self
            item.menu = menu
            failureStatusItem = item
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
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !AppLaunchContext.isBackgroundLaunchEvent(NSAppleEventManager.shared().currentAppleEvent) else { return false }
        if startupError != nil { showStartupError() }
        else { controller?.show() }
        return false
    }

    @objc private func showStartupError() {
        guard let startupError else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L10n.text("mcm could not start")
        alert.informativeText = startupError.localizedDescription
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
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
