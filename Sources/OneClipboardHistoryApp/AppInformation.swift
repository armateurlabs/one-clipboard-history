import AppKit
import OneClipboardHistoryCore

@MainActor
enum AppInformation {
    static let name = "One Clipboard History"
    static let repositoryURL = URL(string: "https://github.com/armateurlabs/one-clipboard-history")!

    enum Document: String, CaseIterable {
        case license = "LICENSE"
        case privacy = "PRIVACY"

        var title: String {
            switch self {
            case .license: L10n.text("MIT License")
            case .privacy: L10n.text("Privacy Policy")
            }
        }

        func url(in bundle: Bundle = .main) -> URL? {
            bundle.url(forResource: rawValue, withExtension: "txt")
        }
    }

    static var isStoreBuild: Bool {
        Bundle.main.bundleIdentifier == "com.armateurlabs.oneclipboardhistory"
            || Bundle.main.object(forInfoDictionaryKey: "OCHMacAppStoreBuild") as? Bool == true
    }

    static func aboutOptions(bundle: Bundle = .main) -> [NSApplication.AboutPanelOptionKey: Any] {
        let credits = NSMutableAttributedString(string: "Armateur Labs\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor
        ])
        func link(_ label: String, to url: URL?) {
            var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
            if let url { attributes[.link] = url }
            credits.append(NSAttributedString(string: label, attributes: attributes))
        }
        link(L10n.text("Source code on GitHub"), to: repositoryURL)
        credits.append(NSAttributedString(string: "\n"))
        link(Document.license.title, to: Document.license.url(in: bundle))
        credits.append(NSAttributedString(string: "  ·  "))
        link(Document.privacy.title, to: Document.privacy.url(in: bundle))
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: name,
            .applicationVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            .version: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            .credits: credits
        ]
        if let icon = bundle.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
            ?? NSApp.applicationIconImage {
            options[.applicationIcon] = icon
        }
        return options
    }
}

/// AppKit owns the About panel. Local documents also remain readable offline,
/// without launching a browser or depending on a Markdown editor being installed.
@MainActor
final class AppInformationController {
    private var documentWindows: [AppInformation.Document: NSWindowController] = [:]

    func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: AppInformation.aboutOptions())
        NSApp.activate()
    }

    func show(_ document: AppInformation.Document) {
        if let controller = documentWindows[document] {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        do {
            guard let url = document.url() else { throw CocoaError(.fileNoSuchFile) }
            let text = try String(contentsOf: url, encoding: .utf8)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 520))
            scroll.hasVerticalScroller = true
            scroll.autoresizingMask = [.width, .height]
            let view = NSTextView(frame: scroll.bounds)
            view.isEditable = false
            view.isSelectable = true
            view.isRichText = false
            view.font = .systemFont(ofSize: 13)
            view.textColor = .labelColor
            view.backgroundColor = .textBackgroundColor
            view.textContainerInset = NSSize(width: 20, height: 20)
            view.autoresizingMask = [.width]
            view.textContainer?.widthTracksTextView = true
            view.string = text
            view.setAccessibilityLabel(document.title)
            scroll.documentView = view
            let window = NSWindow(contentRect: scroll.frame,
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = document.title
            window.contentView = scroll
            window.minSize = NSSize(width: 380, height: 260)
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.center()
            let controller = NSWindowController(window: window)
            documentWindows[document] = controller
            controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.text("Could not open this document.")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    func refreshLocalization() {
        for (document, controller) in documentWindows {
            controller.window?.title = document.title
            (controller.window?.contentView as? NSScrollView)?.documentView?.setAccessibilityLabel(document.title)
        }
    }
}
