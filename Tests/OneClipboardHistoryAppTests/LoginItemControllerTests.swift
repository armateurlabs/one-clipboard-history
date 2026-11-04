import Foundation
import Testing
@testable import OneClipboardHistoryApp

@Suite("Optional login item", .serialized)
@MainActor
struct LoginItemControllerTests {
    @Test func constructionAndRefreshOnlyReadSystemStatus() {
        let service = FakeLoginItemService()
        let controller = LoginItemController(service: service)
        controller.refresh()

        #expect(!controller.isEnabled)
        #expect(!controller.requiresApproval)
        #expect(!controller.isBusy)
        #expect(service.registerCount == 0)
        #expect(service.unregisterCount == 0)
    }

    @Test func enablingAndDisablingUseTheServiceStatus() {
        let service = FakeLoginItemService()
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)
        #expect(controller.isEnabled)
        #expect(!controller.requiresApproval)
        #expect(!controller.isBusy)
        #expect(controller.errorMessage == nil)
        #expect(service.registerCount == 1)

        controller.setEnabled(false)
        #expect(!controller.isEnabled)
        #expect(!controller.requiresApproval)
        #expect(!controller.isBusy)
        #expect(service.unregisterCount == 1)
    }

    @Test func alreadyEnabledOrDisabledRequestsAreIdempotent() {
        let service = FakeLoginItemService(status: .enabled)
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)
        controller.setEnabled(true)
        #expect(controller.isEnabled)
        #expect(service.registerCount == 0)

        controller.setEnabled(false)
        controller.setEnabled(false)
        #expect(!controller.isEnabled)
        #expect(service.unregisterCount == 1)
    }

    @Test func approvalRequiredRemainsRegisteredWithoutRepeatedRegistration() {
        let service = FakeLoginItemService()
        service.registeredStatus = .requiresApproval
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)
        #expect(controller.isEnabled)
        #expect(controller.requiresApproval)
        #expect(service.registerCount == 1)
        controller.refresh()
        controller.setEnabled(true)
        #expect(service.registerCount == 1)
        #expect(controller.requiresApproval)

        controller.setEnabled(false)
        #expect(!controller.isEnabled)
        #expect(!controller.requiresApproval)
        #expect(service.unregisterCount == 1)
    }

    @Test func failedRegistrationRestoresActualStatusAndReportsTheError() {
        let service = FakeLoginItemService()
        service.registerError = failure()
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)

        #expect(!controller.isEnabled)
        #expect(!controller.requiresApproval)
        #expect(!controller.isBusy)
        #expect(controller.errorMessage != nil)
        #expect(service.registerCount == 1)
    }

    @Test func failedUnregistrationKeepsTheActualEnabledStatus() {
        let service = FakeLoginItemService(status: .enabled)
        service.unregisterError = failure()
        let controller = LoginItemController(service: service)

        controller.setEnabled(false)

        #expect(controller.isEnabled)
        #expect(!controller.isBusy)
        #expect(controller.errorMessage != nil)
        #expect(service.unregisterCount == 1)
    }

    @Test func aRegistrationThatWasNotEnabledIsNotPresentedAsSuccessful() {
        let service = FakeLoginItemService()
        service.registeredStatus = .notRegistered
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)

        #expect(!controller.isEnabled)
        #expect(controller.errorMessage != nil)
        #expect(service.registerCount == 1)
    }

    @Test func externallyDisabledItemIsNotRegisteredAgainOnRefresh() {
        let service = FakeLoginItemService(status: .enabled)
        let controller = LoginItemController(service: service)
        service.status = .notRegistered

        controller.refresh()

        #expect(!controller.isEnabled)
        #expect(!controller.requiresApproval)
        #expect(service.registerCount == 0)
        #expect(service.unregisterCount == 0)
    }

    @Test func settingsButtonIsForwardedToTheService() {
        let service = FakeLoginItemService()
        let controller = LoginItemController(service: service)
        controller.openSystemSettings()
        #expect(service.openSettingsCount == 1)
        #expect(service.registerCount == 0)
    }

    @Test func previewOnlyChangesItsInMemoryRegistration() {
        let controller = LoginItemController.preview()
        #expect(!controller.isEnabled)
        controller.setEnabled(true)
        #expect(controller.isEnabled)
        controller.setEnabled(false)
        #expect(!controller.isEnabled)
        #expect(controller.errorMessage == nil)
    }

    private func failure() -> NSError {
        NSError(domain: "com.arthur.mcm.tests.login-item", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Test registration failure"])
    }
}

@MainActor
private final class FakeLoginItemService: LoginItemService {
    var status: LoginItemStatus
    var registeredStatus: LoginItemStatus = .enabled
    var registerError: (any Error)?
    var unregisterError: (any Error)?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSettingsCount = 0

    init(status: LoginItemStatus = .notRegistered) { self.status = status }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = registeredStatus
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }

    func openSystemSettings() { openSettingsCount += 1 }
}
