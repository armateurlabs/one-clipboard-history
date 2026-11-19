# T-100 REPORT.md

## Fait

- `HotkeyRegistrationAPI` converti de `struct` (with closures) en `protocol`
- `CarbonBackend` créé comme `struct` conforme au protocol (API Carbon isolée)
- `GlobalHotkey.init()` default paramètre: `.carbon` → `CarbonBackend.shared`
- `nativeRegistration()` mis à jour pour utiliser les méthodes protocol (named params)
- `FakeRegistrations` dans les tests mis à jour pour conformer au protocol
- Tests existants `GlobalHotkeyTests` (12 tests) passent inchangés
- 7 nouveaux tests ajoutés dans `HotkeyBackendProtocolTests.swift`
- `AppController.swift` inchangé (API publique préservée)
- `swift build -q` passe
- `swift test -q` — 85 tests sur 85 passants

## Non fait

- CGEventTapBackend (prévu pour T-101)
- Secure input detection (prévu pour T-105)
- UI updates (prévu pour T-106)

## Doutes

- Aucun. La refactoring est pure et les tests couvrent les deux cas (Carbon réel et backends fake).

## Fichiers modifiés

| Fichier | Changement |
|---------|------------|
| `Sources/OneClipboardHistoryApp/GlobalHotkey.swift` | Protocol + CarbonBackend |
| `Tests/OneClipboardHistoryAppTests/GlobalHotkeyTests.swift` | FakeRegistrations conforme au protocol |
| `Tests/OneClipboardHistoryAppTests/HotkeyBackendProtocolTests.swift` | **Nouveau** — 7 tests de protocole |
