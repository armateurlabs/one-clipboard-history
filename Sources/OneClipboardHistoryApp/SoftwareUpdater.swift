import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

/// Direct-distribution self-update through Sparkle 2.
///
/// The Mac App Store variant is updated by the Store, so there the updater is
/// compiled out (Sparkle is not linked) and ``isAvailable`` is false.
///
/// Automatic checks are never switched on silently: unless the user already
/// answered, Sparkle asks once (on the second launch) before contacting the
/// appcast, which keeps the app's no-network default honest.
@MainActor
final class SoftwareUpdater {
    #if canImport(Sparkle)
    private let controller: SPUStandardUpdaterController?

    init(bundle: Bundle = .main) {
        let isStoreBuild = bundle.object(forInfoDictionaryKey: "OCHMacAppStoreBuild") as? Bool == true
        let hasFeed = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)?.isEmpty == false
        let hasKey = (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.isEmpty == false
        // Without a feed and a signing key Sparkle would only show an error
        // alert at launch (development builds, previews, unconfigured forks).
        guard !isStoreBuild, hasFeed, hasKey,
              bundle.object(forInfoDictionaryKey: "OCHPreviewMode") as? Bool != true else {
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    var isAvailable: Bool { controller != nil }

    /// User-initiated check; Sparkle presents its own progress and result UI.
    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
    #else
    init(bundle: Bundle = .main) {}
    var isAvailable: Bool { false }
    func checkForUpdates() {}
    #endif
}
