import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let onAccessibility: () -> Void
    let onPasteboardSettings: () -> Void
    let onClear: () -> Void

    var body: some View {
        Form {
            Section("Historique") {
                TextField("Nombre d’entrées", value: $settings.historyLimit, format: .number)
                TextField("Budget de données (Mo)", value: $settings.budgetMegabytes, format: .number)
                Toggle("Conserver l’historique après redémarrage", isOn: $settings.persistenceEnabled)
                Text("Désactiver la conservation supprime la sauvegarde locale. L’historique de cette session reste disponible.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Effacer l’historique…", role: .destructive, action: onClear)
            }
            Section("Raccourci et fenêtre") {
                LabeledContent("Afficher ou masquer") {
                    ShortcutRecorder(shortcut: $settings.shortcut, onRecordingChange: {
                        settings.onShortcutRecordingChange?($0)
                    }).frame(width: 180, height: 26)
                }
                if let error = settings.shortcutError { Text(error).font(.caption).foregroundStyle(.red) }
                Toggle("Ouvrir au pointeur de la souris", isOn: $settings.positionAtPointer)
                Text("Déplacer la fenêtre mémorise sa position et désactive l’ouverture au pointeur.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Masquer après collage", isOn: $settings.hideAfterPasting)
            }
            Section("Affichage") {
                Toggle("Afficher les aperçus des images", isOn: $settings.showPreviews)
                Toggle("Afficher la taille des données", isOn: $settings.showSizes)
            }
            Section("Autorisations") {
                Button("Autoriser le collage automatique…", action: onAccessibility)
                Button("Réglages de lecture du presse-papiers…", action: onPasteboardSettings)
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 490, height: 680)
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
        return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.onRecord = { shortcut = $0 }
        button.onRecordingChange = onRecordingChange
        button.shortcutLabel = shortcut.label
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
        toolTip = "Cliquer puis appuyer sur le nouveau raccourci. Échap pour annuler."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func beginRecording() {
        recording = true
        onRecordingChange?(true)
        title = "Appuyez sur les touches…"
        window?.makeFirstResponder(self)
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { finish(); return }
        guard let shortcut = KeyboardShortcut(event: event) else {
            title = "Ajouter ⌥, ⌘ ou ⌃"
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
