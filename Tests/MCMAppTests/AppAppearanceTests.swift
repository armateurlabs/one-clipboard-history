import AppKit
import SwiftUI
import Testing
@testable import MCMApp

@Suite("Application appearance", .serialized)
@MainActor
struct AppAppearanceTests {
    @Test func historyPanelInheritsForcedThemesAndReturnsToSystemAppearance() throws {
        let application = NSApplication.shared
        let previousAppearance = application.appearance
        defer { application.appearance = previousAppearance }
        let panel = HistoryPanelController()
        let window = try #require(panel.window)
        let content = try #require(window.contentView)

        AppAppearance.apply(.dark)
        expectInheritedAppearance(.darkAqua, application: application, window: window, view: content)
        AppAppearance.apply(.light)
        expectInheritedAppearance(.aqua, application: application, window: window, view: content)
        AppAppearance.apply(.system)
        expectSystemAppearance(application: application, window: window, view: content)
        #expect(!window.isVisible)
    }

    @Test func actualSwiftUISettingsWindowInheritsLiveAppearanceChanges() throws {
        let application = NSApplication.shared
        let previousAppearance = application.appearance
        let suiteName = "com.arthur.mcm.appearance-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            application.appearance = previousAppearance
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = AppSettings(defaults: defaults)
        let hosting = NSHostingController(rootView: SettingsView(
            settings: settings, onAccessibility: {}, onPasteboardSettings: {}, onClear: {}
        ))
        let window = NSWindow(contentViewController: hosting)

        AppAppearance.apply(.dark)
        expectInheritedAppearance(.darkAqua, application: application, window: window, view: hosting.view)
        AppAppearance.apply(.light)
        expectInheritedAppearance(.aqua, application: application, window: window, view: hosting.view)
        AppAppearance.apply(.system)
        expectSystemAppearance(application: application, window: window, view: hosting.view)
        #expect(!window.isVisible)
        #expect(settings.appearanceMode == .system)
    }

    private func expectInheritedAppearance(
        _ expected: NSAppearance.Name, application: NSApplication, window: NSWindow, view: NSView
    ) {
        #expect(application.appearance?.name == expected)
        #expect(window.appearance == nil)
        #expect(view.appearance == nil)
        #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
        #expect(view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
    }

    private func expectSystemAppearance(application: NSApplication, window: NSWindow, view: NSView) {
        let system = application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        #expect(application.appearance == nil)
        #expect(window.appearance == nil)
        #expect(view.appearance == nil)
        #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == system)
        #expect(view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == system)
    }
}
