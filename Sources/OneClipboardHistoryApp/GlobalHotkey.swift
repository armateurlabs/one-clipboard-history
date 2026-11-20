import AppKit
import Carbon

@MainActor
protocol HotkeyRegistrationAPI {
    func register(_ shortcut: KeyboardShortcut,
                  identifier: EventHotKeyID,
                  options: UInt32) -> (OSStatus, EventHotKeyRef?)
    func unregister(_ reference: EventHotKeyRef) -> OSStatus
}

@MainActor
struct CarbonBackend: HotkeyRegistrationAPI {
    static let shared = CarbonBackend()
    private init() {}

    func register(_ shortcut: KeyboardShortcut,
                  identifier: EventHotKeyID,
                  options: UInt32) -> (OSStatus, EventHotKeyRef?) {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier,
                                         GetApplicationEventTarget(), options, &reference)
        return (status, reference)
    }

    func unregister(_ reference: EventHotKeyRef) -> OSStatus {
        UnregisterEventHotKey(reference)
    }
}

@MainActor
final class GlobalHotkey {

    // MARK: - Backend type

    /// Indicates which backend is currently active.
    enum BackendType {
        case carbon
        case cgEventTap
    }

    // MARK: - Properties

    private static var nextID: UInt32 = 0
    nonisolated let eventID: UInt32
    private(set) var backendType: BackendType = .carbon

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let api: HotkeyRegistrationAPI
    private var suspendedShortcut: KeyboardShortcut?
    private var cleanupReferences: [EventHotKeyRef] = []
    private var stopped = false
    private(set) var currentShortcut: KeyboardShortcut?
    private(set) var lastError: OSStatus?
    var hasActiveShortcut: Bool { !stopped && reference != nil && cleanupReferences.isEmpty }
    var onPressed: (() -> Void)?
    var onSecureInputDetected: (() -> Void)?

    /// Checks whether macOS is currently in secure-input mode.
    /// Calls ``onSecureInputDetected`` when secure input is active so that
    /// the app can inform the user that the shortcut is temporarily disabled.
    func checkSecureInput() {
        guard !stopped else { return }
        if CGEventTapHotkey.isSecureInputActive() {
            onSecureInputDetected?()
        }
    }

    // MARK: - Init

    init(api: HotkeyRegistrationAPI = CarbonBackend.shared) {
        let selectedApi = Self.selectBackend(api: api)
        self.api = selectedApi
        self.backendType = selectedApi is CGEventTapHotkey ? .cgEventTap : .carbon

        Self.nextID &+= 1
        eventID = Self.nextID
        _ = installHandlerIfNeeded()

        // Connect CGEventTapHotkey's onPressed to GlobalHotkey's onPressed,
        // but guard against macOS secure-input mode (password fields, Keychain)
        // and against inactive state (fix #6: parity with Carbon handler).
        if let cgBackend = selectedApi as? CGEventTapHotkey {
            cgBackend.onPressed = { [weak self] in
                guard let self, self.hasActiveShortcut else { return }
                if CGEventTapHotkey.isSecureInputActive() {
                    self.onSecureInputDetected?()
                } else {
                    self.onPressed?()
                }
            }
        }
    }

    /// Cached result of the CGEventTap availability probe (fix #9:
    /// avoid a side-effecting probe on every init).
    private static var cachedCGEventTapAvailable: Bool?

    /// Select the best available backend.
    ///
    /// If a custom API is provided (not ``CarbonBackend``), use it directly.
    /// Otherwise try ``CGEventTapHotkey`` first and fall back to
    /// ``CarbonBackend/shared`` when the tap cannot be created.
    private static func selectBackend(api: HotkeyRegistrationAPI) -> HotkeyRegistrationAPI {
        // Custom backend provided — use it as-is.
        guard api is CarbonBackend else { return api }

        // Use cached probe result if available.
        if let cached = cachedCGEventTapAvailable {
            return cached ? CGEventTapHotkey() : CarbonBackend.shared
        }

        // Try CGEventTapHotkey first (auto-detect path).
        let cgBackend = CGEventTapHotkey()
        let testShortcut = KeyboardShortcut(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(optionKey),
            keyLabel: "A"
        )
        let (status, ref) = cgBackend.register(testShortcut,
            identifier: EventHotKeyID(signature: 0x4D434D48, id: 0),
            options: UInt32(kEventHotKeyExclusive))

        // Clean up the test registration.
        if status == noErr, let ref {
            _ = cgBackend.unregister(ref)
        }

        let available = status == noErr
        cachedCGEventTapAvailable = available
        return available ? cgBackend : CarbonBackend.shared
    }

    // MARK: - Event handler

    private func installHandlerIfNeeded() -> Bool {
        if handler != nil { return true }
        // CGEventTapHotkey handles events through its own tap callback.
        guard backendType == .carbon else { return true }

        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == 0x4D434D48 else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue()
            guard identifier.id == hotkey.eventID else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in
                guard hotkey.hasActiveShortcut else { return }
                hotkey.onPressed?()
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if installed != noErr { lastError = installed }
        return installed == noErr && handler != nil
    }

    // MARK: - Public API

    func register(_ shortcut: KeyboardShortcut, force: Bool = false) -> Bool {
        guard !stopped, installHandlerIfNeeded() else { return false }
        guard cleanUpProvisionalRegistrations() else { return false }
        if let currentShortcut, currentShortcut.hasSameKeyCombination(as: shortcut) {
            if !force {
                self.currentShortcut = shortcut
                lastError = nil
                return true
            }
            if !suspend() {
                let failure = lastError
                guard let recovered = nativeRegistration(shortcut) else {
                    lastError = failure
                    return false
                }
                reference = recovered
                self.currentShortcut = shortcut
                suspendedShortcut = nil
                return true
            }
        }
        guard let next = nativeRegistration(shortcut) else {
            let failure = lastError
            if reference == nil, let previous = suspendedShortcut,
               let restored = nativeRegistration(previous) {
                reference = restored
                currentShortcut = previous
                if previous.hasSameKeyCombination(as: shortcut) {
                    suspendedShortcut = nil
                    return true
                }
            }
            suspendedShortcut = nil
            lastError = failure
            return false
        }
        if let reference {
            let status = api.unregister(reference)
            if status != noErr {
                if api.unregister(next) != noErr { cleanupReferences.append(next) }
                lastError = status
                return false
            }
        }
        reference = next
        currentShortcut = shortcut
        suspendedShortcut = nil
        return true
    }

    private func nativeRegistration(_ shortcut: KeyboardShortcut) -> EventHotKeyRef? {
        let (status, next) = api.register(shortcut,
            identifier: EventHotKeyID(signature: 0x4D434D48, id: eventID),
            options: UInt32(kEventHotKeyExclusive))
        guard status == noErr, let next else {
            lastError = status == noErr ? OSStatus(eventNotHandledErr) : status
            return nil
        }
        lastError = nil
        return next
    }

    func stop() {
        suspend()
        suspendedShortcut = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        stopped = true
    }

    @discardableResult
    func suspend() -> Bool {
        guard cleanUpProvisionalRegistrations() else { return false }
        if let reference {
            let status = api.unregister(reference)
            guard status == noErr else {
                lastError = status
                return false
            }
        }
        if let currentShortcut { suspendedShortcut = currentShortcut }
        reference = nil
        currentShortcut = nil
        return true
    }

    private func cleanUpProvisionalRegistrations() -> Bool {
        cleanupReferences = cleanupReferences.filter { reference in
            let status = api.unregister(reference)
            if status != noErr { lastError = status }
            return status != noErr
        }
        return cleanupReferences.isEmpty
    }
}
