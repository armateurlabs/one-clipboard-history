import AppKit
import SwiftUI
import MCMCore

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let onAccessibility: () -> Void
    let onPasteboardSettings: () -> Void
    let onClear: () -> Void

    var body: some View {
        Form {
            Section(L10n.text("History")) {
                TextField(L10n.text("Number of entries"), value: $settings.historyLimit, format: .number)
                TextField(L10n.text("Data budget (MiB)"), value: $settings.budgetMegabytes, format: .number)
                Toggle(L10n.text("Keep history after restarting"), isOn: $settings.persistenceEnabled)
                Text(L10n.text("Turning this off deletes the local backup. This session’s history remains available."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L10n.text("Clear history…"), role: .destructive, action: onClear)
            }
            Section(L10n.text("Shortcut and window")) {
                LabeledContent(L10n.text("Show or hide")) {
                    ShortcutRecorder(shortcut: $settings.shortcut, onRecordingChange: {
                        settings.onShortcutRecordingChange?($0)
                    }).frame(width: 180, height: 26)
                }
                if let error = settings.shortcutError { Text(L10n.text(error)).font(.caption).foregroundStyle(.red) }
                Toggle(L10n.text("Open at the mouse pointer"), isOn: $settings.positionAtPointer)
                LabeledContent(L10n.text("Window position around pointer")) {
                    PointerQuadrantPicker(selection: $settings.pointerQuadrant)
                        .disabled(!settings.positionAtPointer)
                }
                Text(L10n.text("Moving the window remembers its position and turns off opening at the pointer."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.text("Hide after pasting"), isOn: $settings.hideAfterPasting)
                Toggle(L10n.text("Animate window appearance"), isOn: $settings.animationsEnabled)
                Text(L10n.text("Off by default: the window appears and disappears instantly."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("Appearance")) {
                Toggle(L10n.text("Compact view"), isOn: $settings.compactView)
                Text(L10n.text("Fit rows to their content without changing text or preview size."))
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent(L10n.text("History font size")) {
                    HStack(spacing: 12) {
                        Slider(value: $settings.historyFontSize, in: 10...28, step: 1)
                            .accessibilityLabel(L10n.text("History font size"))
                        Text(L10n.format("%@ pt", settings.historyFontSize.formatted(
                            .number.precision(.fractionLength(0...1)).locale(L10n.currentLocale)
                        )))
                        .monospacedDigit()
                        .frame(minWidth: 48, alignment: .trailing)
                    }.frame(width: 240)
                }
                Toggle(L10n.text("Show image previews"), isOn: $settings.showPreviews)
                Toggle(L10n.text("Show data size"), isOn: $settings.showSizes)
                Picker(L10n.text("Language"), selection: $settings.language) {
                    Text(L10n.text("System language")).tag(AppLanguage.system)
                    Text(L10n.text("French")).tag(AppLanguage.french)
                    Text(L10n.text("English")).tag(AppLanguage.english)
                }
            }
            Section(L10n.text("Permissions")) {
                Button(L10n.text("Allow automatic pasting…"), action: onAccessibility)
                Button(L10n.text("Clipboard access settings…"), action: onPasteboardSettings)
            }
        }
        .formStyle(.grouped)
        .environment(\.locale, L10n.currentLocale)
        .padding(8)
        .frame(width: 520, height: 740)
    }
}

private struct PointerQuadrantPicker: View {
    @Binding var selection: PointerQuadrant

    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    quadrantButton(.topLeft, symbol: "arrow.up.left", label: L10n.text("Top left"))
                    quadrantButton(.topRight, symbol: "arrow.up.right", label: L10n.text("Top right"))
                }
                HStack(spacing: 8) {
                    quadrantButton(.bottomLeft, symbol: "arrow.down.left", label: L10n.text("Bottom left"))
                    quadrantButton(.bottomRight, symbol: "arrow.down.right", label: L10n.text("Bottom right"))
                }
            }
            Image(systemName: "cursorarrow")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(.background, in: Circle())
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .padding(8)
        .frame(width: 96, height: 96)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Window position around pointer"))
    }

    private func quadrantButton(_ quadrant: PointerQuadrant, symbol: String, label: String) -> some View {
        Button {
            selection = quadrant
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 24)
                .foregroundStyle(selection == quadrant ? Color.white : Color.primary)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.mini)
        .tint(selection == quadrant ? Color.accentColor : Color(nsColor: .controlColor))
        .frame(width: 36, height: 36)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selection == quadrant ? .isSelected : [])
        .help(label)
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: KeyboardShortcut
    let onRecordingChange: (Bool) -> Void
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        button.onRecord = { shortcut = $0 }
        button.onRecordingChange = onRecordingChange
        button.title = shortcut.label
        button.shortcutLabel = shortcut.label
        button.toolTip = L10n.text("Click, then press the new shortcut. Escape cancels.")
        return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.onRecord = { shortcut = $0 }
        button.onRecordingChange = onRecordingChange
        button.shortcutLabel = shortcut.label
        button.toolTip = L10n.text("Click, then press the new shortcut. Escape cancels.")
        if !button.recording { button.title = shortcut.label }
    }
}

@MainActor
private final class RecorderButton: NSButton {
    var onRecord: ((KeyboardShortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    var shortcutLabel = "⌥A"
    var recording = false
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        target = self
        action = #selector(beginRecording)
        toolTip = L10n.text("Click, then press the new shortcut. Escape cancels.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func beginRecording() {
        recording = true
        onRecordingChange?(true)
        title = L10n.text("Press the keys…")
        window?.makeFirstResponder(self)
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { finish(); return }
        guard let shortcut = KeyboardShortcut(event: event) else {
            title = L10n.text("Add ⌥, ⌘ or ⌃")
            return
        }
        onRecord?(shortcut)
        finish()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
    override func resignFirstResponder() -> Bool { finish(); return super.resignFirstResponder() }
    private func finish() {
        let wasRecording = recording
        recording = false
        title = shortcutLabel
        if wasRecording { onRecordingChange?(false) }
    }
}
