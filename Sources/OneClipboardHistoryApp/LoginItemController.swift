import AppKit
import Combine
import OneClipboardHistoryCore
import ServiceManagement

enum LoginItemStatus: Sendable {
    case notRegistered, enabled, requiresApproval, notFound
}

@MainActor
protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
private final class SystemLoginItemService: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// macOS owns this preference. Reading it never registers or re-enables an item
/// that the user has disabled outside One Clipboard History.
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    private let service: any LoginItemService

    convenience init() { self.init(service: SystemLoginItemService()) }

    init(service: any LoginItemService) {
        self.service = service
        refresh()
    }

    static func preview() -> LoginItemController {
        LoginItemController(service: PreviewLoginItemService())
    }

    func refresh() {
        guard !isBusy else { return }
        updateStatus()
        errorMessage = service.status == .notFound
            ? L10n.text("Launch at login is unavailable. Open the installed One Clipboard History application and try again.") : nil
    }

    func setEnabled(_ enabled: Bool) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let before = service.status
            if enabled, before != .enabled, before != .requiresApproval {
                try service.register()
            } else if !enabled, before == .enabled || before == .requiresApproval {
                try service.unregister()
            }
            updateStatus()
            if service.status == .notFound {
                errorMessage = L10n.text("Launch at login is unavailable. Open the installed One Clipboard History application and try again.")
            } else if enabled, !isEnabled {
                errorMessage = L10n.text("macOS did not enable launch at login.")
            }
        } catch {
            updateStatus()
            errorMessage = L10n.format("Could not change launch at login: %@", error.localizedDescription)
        }
    }

    func openSystemSettings() { service.openSystemSettings() }

    private func updateStatus() {
        let status = service.status
        requiresApproval = status == .requiresApproval
        // A pending registration stays removable; the adjacent approval message
        // distinguishes it from an enabled service.
        isEnabled = status == .enabled || requiresApproval
    }
}

@MainActor
private final class PreviewLoginItemService: LoginItemService {
    var status: LoginItemStatus = .notRegistered
    func register() throws { status = .enabled }
    func unregister() throws { status = .notRegistered }
    func openSystemSettings() {}
}
