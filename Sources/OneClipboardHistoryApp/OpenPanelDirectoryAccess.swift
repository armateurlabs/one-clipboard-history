import Foundation

/// Owns the implicit security scope supplied by NSOpenPanel. Capturing this
/// object in queued work also releases a selection if that work never runs.
final class OpenPanelDirectoryAccess: Sendable {
    let url: URL
    private let release: @Sendable (URL) -> Void

    init(url: URL, release: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.url = url
        self.release = release
    }

    deinit { release(url) }
}
