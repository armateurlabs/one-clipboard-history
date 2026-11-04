import AppKit
import Carbon

enum AppLaunchContext {
    static func isBackgroundLaunchEvent(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) || event.eventID == AEEventID(kAEReopenApplication),
              let reason = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue else { return false }
        return reason == OSType(keyAELaunchedAsLogInItem) || reason == OSType(keyAELaunchedAsServiceItem)
    }
}
