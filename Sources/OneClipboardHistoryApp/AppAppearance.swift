import AppKit

@MainActor
enum AppAppearance {
    static func apply(_ mode: AppearanceMode) {
        let appearance: NSAppearance?
        switch mode {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        let application = NSApplication.shared
        guard application.appearance?.name != appearance?.name else { return }
        // A nil override lets AppKit follow future system changes automatically.
        // Windows, native controls and SwiftUI hosts all inherit this appearance.
        application.appearance = appearance
    }
}
