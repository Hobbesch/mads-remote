# mads Remote

Eine schlanke **iOS-Companion-App** (iPad + iPhone), die eine im lokalen Netz laufende
[mads](https://github.com/Hobbesch/mads)-Instanz **spiegelt** und **fernsteuert** — „als säße man
direkt an mads". Streams-Übersicht, Inspector (Chat/Git/PR/Gate/Dev-Server), Composer, Aktionen und
ein Markdown-Editor, alles über eine LAN-lokale, verschlüsselte Verbindung.

> **Status:** Bau-Basis. Der Plan steht in [`docs/architecture.md`](docs/architecture.md).

## Architektur in einem Satz

Thin client, dickes Backend: mads bleibt Single Source of Truth. Die App rendert Zustand und sendet
Intents über **dasselbe Protokoll** (`shared/protocol.ts`) wie das mads-Frontend — nur über **WSS
(TLS 1.3) im LAN** statt über Tauri-IPC. Discovery via **mDNS `_mads-remote._tcp`**, Kopplung via
**PIN/QR → widerrufbares Geräte-Token**, Transport **SPKI-Pinning (TOFU)**.

Die Arbeit umfasst zwei Repos:

- **`mads-remote`** (dieses Repo) — die iOS-App (SwiftUI, Swift 6, iOS 18+).
- **`mads`** (bestehend) — die Remote-Bridge im Rust-Core. Siehe [`docs/mads-bridge.md`](docs/mads-bridge.md).

## Tech-Stack

| | |
|---|---|
| **UI** | SwiftUI, iOS 18.0+, Swift 6.3 (strict concurrency), `@Observable` |
| **Discovery** | `NWBrowser` (Network.framework) |
| **Transport** | `URLSessionWebSocketTask` + TLS-1.3-SPKI-Pinning |
| **Editor** | CodeMirror 6 in `WKWebView` (offline gebündelt) |
| **Projekt** | xcodegen (`project.yml`), Swift Testing |
| **Sicherheit** | Keychain-Token, Argon2id-Server-Token, per-Verbindungs-`FsScope` |

## Entwicklung

> Voraussetzungen: Xcode 26+, `xcodegen`, `node` (für das Editor-Bundle).

```bash
make gen        # Xcode-Projekt aus project.yml generieren (.xcodeproj ist gitignored)
make editor     # CodeMirror-6-Bundle bauen → App/Resources/editor/
open mads-remote.xcodeproj
```

## Sicherheit & Repo-Hygiene

- **Keine Secrets im Repo.** Signing-Material (`*.p8`, `*.mobileprovision`), Zertifikate und `.env`
  sind gitignored; `.gitleaks.toml` scannt fail-closed.
- Das Dev-TLS-Zertifikat der Bridge wird **zur Laufzeit am Mac** erzeugt und nie committet.
- Sicherheits-Threat-Model + Checkliste: [`docs/architecture.md` §6](docs/architecture.md#6-sicherheitsmodell--checkliste).

## Lizenz

[MIT](LICENSE) © 2026 Alessandro
