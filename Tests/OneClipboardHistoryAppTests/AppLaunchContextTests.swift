import AppKit
import Carbon
import Testing
@testable import OneClipboardHistoryApp

@Suite("Silent session launch events")
struct AppLaunchContextTests {
    @Test func loginAndServiceLaunchesDoNotRequestAWindowEvenWhenReopening() {
        for identifier in [kAEOpenApplication, kAEReopenApplication] {
            for reason in [keyAELaunchedAsLogInItem, keyAELaunchedAsServiceItem] {
                #expect(AppLaunchContext.isBackgroundLaunchEvent(event(id: identifier, reason: reason)))
            }
        }
    }

    @Test func normalUserLaunchesAndReopensRemainInteractive() {
        #expect(!AppLaunchContext.isBackgroundLaunchEvent(nil))
        #expect(!AppLaunchContext.isBackgroundLaunchEvent(event(id: kAEOpenApplication)))
        #expect(!AppLaunchContext.isBackgroundLaunchEvent(event(id: kAEReopenApplication)))
        #expect(!AppLaunchContext.isBackgroundLaunchEvent(event(id: kAEOpenDocuments, reason: keyAELaunchedAsLogInItem)))
    }

    private func event(id: AEEventID, reason: OSType? = nil) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(id),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        if let reason { event.setParam(NSAppleEventDescriptor(enumCode: OSType(reason)), forKeyword: AEKeyword(keyAEPropData)) }
        return event
    }
}
