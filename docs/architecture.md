# mads Remote — Architektur- & Entscheidungs-Dokument

> Status: **Bau-Basis** (2026-07-07). Leitet die Umsetzung der iOS-Companion-App **plus**
> der mads-seitigen Remote-Bridge. Verankert im echten mads-Protokoll (`shared/protocol.ts`)
> und dem `FsScope`-Sicherheitsmodell (`src-tauri/src/files.rs`).
> Prosa deutsch, Code-/Protokoll-Begriffe englisch (wie im übrigen mads-Code).
>
> Grundlage: [`remote-companion-app.md`](../../mads/docs/design/remote-companion-app.md) (Konzept)
> + recherchegestützte Verifikation des aktuellen Framework-/Crate-Stands (Xcode 26.6, Swift 6.3.3,
> iOS SDK 26.5) und der [Security-Checkliste](#6-sicherheitsmodell--checkliste).

---

## 1. Zweck & Scope

**mads Remote** spiegelt und fernsteuert eine im LAN laufende mads-Instanz — „als säße man an mads".
Die Arbeit umfasst **zwei Repos**:

| Repo | Inhalt |
|------|--------|
| **`mads-remote`** (dieses Repo) | Die iOS-App (SwiftUI, iPad + iPhone). |
| **`mads`** (bestehend, eigenes Git/PR) | Die Remote-Bridge (`src-tauri/src/bridge.rs` + kleine Änderungen an `files.rs`/`sidecar.rs`/`lib.rs`) und der neue `request_snapshot`-Typ in `shared/protocol.ts`. |

**Nicht-Ziele:** kein zweiter Orchestrator; kein Cloud-/Relay-Dienst (rein LAN); kein Ersatz für den
Mac. Die App ist ein **Fenster + Fernbedienung**.

---

## 2. Gesperrte Entscheidungen

Aus dem Konzept (OE-R1…R9) + neue Entscheidungen (NEW-*), nach Recherche und Nutzer-Freigabe.

| ID | Frage | Entscheidung | Begründung |
|----|-------|--------------|------------|
| **OE-R1** | Bridge-Ort | **In-Process-Modul** `src-tauri/src/bridge.rs`, eigener tokio-Task | Teet Sidecar-stdout roh + nutzt `sidecar_send`; keine IPC-Neuverdrahtung. Tauri linkt tokio bereits. |
| **OE-R2** | Discovery | **mDNS `_mads-remote._tcp`** — `mdns-sd` (Mac) ↔ `NWBrowser` (iOS) | Beide Seiten nativ/pur; TXT trägt `name/host/pid/project/pv/fp`. |
| **OE-R3** | TLS + Pinning | **rustls self-signed Leaf, TLS 1.3 only, SPKI-SHA256-TOFU-Pinning** | SPKI-Pin überlebt Leaf-Rotation ohne Neu-Pairing. Konzept-Prämisse „NWConnection nötig fürs Pinning" ist falsch — beide iOS-APIs erlauben Custom-Validierung. |
| **OE-R4** | Pairing | **PIN + QR**; QR trägt `host:port + SPKI-fp + Einmal-Code`; PIN 60 s TTL, ≤5 Versuche | Fingerprint über den menschlich-verifizierten Kanal, nicht nur über sniffbaren mDNS-TXT. |
| **OE-R5** | Außen-sichtbare Aktionen aus der Ferne | **Extra-Bestätigung am Mac, an per Default** für `integrate_pr`, `update_main`, `create_pr`, `shutdown`, `set_autonomy`; als Toggle abschaltbar | Irreversibel/außen-sichtbar; sicherer Default (gestohlenes Token macht nicht trivial `shutdown`). |
| **OE-R6** | Bild-Transport | **Binär-WS-Frame**, per Envelope-`id` korreliert (für `write_file_bytes`) | JSON-Zahlen-Array ist 3–4× Overhead. |
| **OE-R7** | md-Editor iOS | **CodeMirror 6 in WKWebView**, offline gebündelt (esbuild IIFE); nativ (`UITextView` + `swift-markdown`) als dokumentierter Fallback | Exakte Parität zu mads' `cmMarkdown` (Suche/GFM/Split gratis). Natives `AttributedString(markdown:)` ist inline-only → als Preview unbrauchbar. |
| **OE-R8** | WS-Client-API iOS | **`URLSessionWebSocketTask`** + Session-`URLSessionDelegate`-Trust-Callback | Native WS-Framing + ping/pong + async `receive()`. Trust-Logik am **Session**-Delegate (nicht Task-Delegate — sonst feuert das Pinning nie). |
| **OE-R9** | Per-Verbindungs-Scope | **Ein `FsScope` pro Socket** (`ConnScope.fs`), scope-parametrisierte inner-fns | Verengt, umgeht nie `ensure_in_scope`; behebt den prozessglobalen `Mutex`-Leak (§9.5). |
| **NEW-1** | iOS-Deployment-Floor | **iOS 18.0**; iOS-26-only-APIs hinter `if #available(iOS 26, *)` | Reifes `@Observable`; strandet keinen iPad auf einem hinterherhängenden Point-Release. |
| **NEW-2** | Projekt-Generator | **xcodegen** (textuelles `project.yml`, kein committetes `.pbxproj`) | Diffbar, kein pbxproj-Merge-Hell. |
| **NEW-3** | Swift-Concurrency | **Swift-6-Sprachmodus, `SWIFT_STRICT_CONCURRENCY=complete`** | Greenfield; erzwingt korrekte Socket-Loop-Isolation von Tag 1. |
| **NEW-4** | mDNS-Crate (Mac) | **`mdns-sd 0.20`** | Gepflegt, pur-Rust, advertise+browse, sauberes TXT + Multi-Interface. |
| **NEW-5** | WSS-Server-Crate | **`tokio-tungstenite 0.29`** (nicht axum) | Ein WSS-Endpoint, kein REST-Surface; minimale Deps + direkte Frame-Kontrolle für OE-R6. |
| **NEW-6** | Token-Format | **Opaque ≥256-bit CSPRNG-Wert, Argon2id-gehasht in SQLite** (kein JWT) | Serverseitig widerrufbar; keine `alg:none`/Algorithmen-Confusion-Fläche. |
| **NEW-7** | Sanitizer-Ort | **Auf dem Mac (Node-Sidecar)**; iOS rendert inertes HTML mit deaktiviertem JS | Autorität bleibt auf der vertrauenswürdigen Seite; Defense-in-Depth. |
| **AUTH** | Auth-Modell v1 | **Bearer-Token** (NEW-6); mTLS als spätere Aufrüstung dokumentiert | Einfacher, für Start ausreichend. |

---

## 3. Ziel-Stack (exakte Versionen)

### 3a. iOS-App
- **SwiftUI**, iOS-18.0-Floor, **Swift 6.3.3 / Xcode 26.6**, `SWIFT_STRICT_CONCURRENCY=complete`.
- **State:** Observation (`@Observable @MainActor final class InstanceStore`); Socket in einem
  `actor`; genau ein `await store.apply(msg)`-MainActor-Hop.
- **Transport:** `URLSessionWebSocketTask` + `URLSession(configuration:delegate:delegateQueue:)`;
  Trust-Logik am **Session**-Delegate.
- **Discovery:** `NWBrowser` mit `.bonjourWithTXTRecord(type: "_mads-remote._tcp", domain: nil)`,
  `NWParameters.includePeerToPeer = true`.
- **Keychain:** rohes `SecItem`, `kSecClassGenericPassword`,
  **`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`** (Locked-Background-Reconnect, kein
  iCloud-Sync/Backup). Zwei Items pro Instanz: Token + gepinnter SPKI.
- **QR:** Scan = `DataScannerViewController` (VisionKit); Anzeige = Core Image
  `CIFilter.qrCodeGenerator()`.
- **Editor-WebView:** gebündeltes **CodeMirror 6** — `@codemirror/state 6.7.1`,
  `@codemirror/view 6.43.0`, `codemirror 6.0.2` + `commands`/`search`/`lang-markdown`, esbuild-IIFE
  → `App/Resources/editor/`.
- **Tests:** Swift Testing (`import Testing`, `@Test`, `#expect`).

### 3b. Rust-Bridge (`Cargo.toml`-Ergänzungen im mads-Repo)
```toml
tokio-tungstenite = { version = "0.29", features = ["rustls-tls-webpki-roots"] }
tokio             = { version = "1.52", features = ["rt-multi-thread","net","io-util","sync","macros"] }
futures-util      = "0.3"
rustls            = "0.23"          # aws-lc-rs Default-Provider
tokio-rustls      = "0.26"
rustls-pki-types  = "1"
rcgen             = "0.14"          # Feld heißt `signing_key`, cert.der()
mdns-sd           = "0.20"
rusqlite          = { version = "0.40", features = ["bundled"] }
argon2            = "0.5"           # nicht 0.6-rc
subtle            = "2.6"
# sha2 bereits vorhanden (files.rs) — für SPKI-fp wiederverwenden. rand/getrandom für Salts+Token.
```
- **TLS:** TLS 1.3 only (`rustls::version::TLS13`), nur AES-256-GCM / ChaCha20-Poly1305,
  **`max_early_data_size = 0`** (kein 0-RTT — Command-Plane ist nicht idempotent). Leaf: SAN über
  mDNS-Host + LAN-IPs, `CA:FALSE`, `serverAuth`-EKU. Cert/Key persistieren (PKCS#8 PEM, Mode 0600 in
  App-Support) → gepinnter fp bleibt über Neustarts stabil.
- **WS-Caps:** `max_message_size`/`max_frame_size` ~8–16 MB; 15 s Heartbeat + Dead-Socket-Reaping.
- **Rate-Limit:** handgerollter per-`device_id`-Token-Bucket.

### 3c. Sidecar-Änderungen (nur TypeScript, null Rust-Protokoll-Code)
- `shared/protocol.ts`: `RequestSnapshotMsg extends BaseMsg { type: "request_snapshot" }` in die
  `HostMessage`-Union aufnehmen.
- Node-Sidecar: `request_snapshot` behandeln → aktuellen Stand über bestehende Nachrichten
  re-emittieren (`project_resolved`, je Agent `status_update`+`git_status`+`pr_update`+`gate_result`+
  `devserver_status`+`cost_update`, `resumable_agents`, `reconcile_summary`).
- **Raw-Passthrough bestätigt:** die Bridge forwarded Client-JSON direkt in `sidecar_send` (stdin);
  Snapshot-Antworten kommen über den geteeten stdout zurück. Rust bleibt protokoll-dünn.

---

## 4. Repo- & Modul-Layout (`mads-remote`)

```
mads-remote/
├── project.yml                 # xcodegen-Spec — Quelle der Wahrheit, committet
├── Makefile                    # `make gen` → xcodegen; `make editor` → esbuild-Bundle
├── .gitignore                  # *.xcodeproj/, build/, DerivedData/, *.p8/*.mobileprovision, node_modules/
├── .gitleaks.toml              # fail-closed Secret-Scan
├── README.md
├── docs/
│   ├── architecture.md         # dieses Dokument
│   └── mads-bridge.md          # verweist auf die mads-seitigen Bridge-Pfade (anderes Repo)
├── editor/                     # CodeMirror-6-Quelle → offline gebündelt
│   ├── package.json            # @codemirror/* gepinnt; package-lock.json committet
│   ├── src/editor.ts
│   └── build.mjs               # esbuild-IIFE → App/Resources/editor/editor.bundle.{js,css}
├── App/
│   ├── Resources/
│   │   ├── editor/             # GENERIERTES Bundle (gitignored, via CI/`make editor`)
│   │   ├── Info.plist          # NSLocalNetworkUsageDescription, NSBonjourServices, NSCameraUsageDescription
│   │   └── Assets.xcassets/
│   └── Sources/
│       ├── App/                # @main App, ScenePhase, Root-NavigationSplitView
│       ├── Discovery/          # NWBrowser-Wrapper, Instance-Model, TXT-Parsing
│       ├── Transport/          # SocketConnection (actor), URLSessionWebSocketTask, TOFU-Trust-Delegate
│       ├── Protocol/           # Codable-Spiegel von protocol.ts (Enums nach type/kind gekeyed)
│       ├── State/              # InstanceStore (@Observable @MainActor), reducer apply(_:)
│       ├── Pairing/            # DataScanner (QR), PIN-Eingabe
│       ├── Security/           # KeychainStore (SecItem), SPKI-Fingerprint-Vergleich
│       ├── Editor/             # WKWebView-Host, WKScriptMessageHandler-Bridge, ConflictSheet, OpenFile
│       ├── FileRPC/            # read_file/write_file/register_root-Client, Optimistic-Concurrency
│       └── UI/                 # Timeline, Agent-Views, Permission-Request-Views
└── Tests/
    └── madsRemoteTests/        # Swift Testing: Reducer, Protokoll-Codec, Concurrency, Conflict-Logik
```

**Hygiene-Regeln:** nur textuelles `project.yml` (nie `.xcodeproj` committen); keine Secrets im Repo
(Dev-Cert/Key wird zur Laufzeit am Mac erzeugt, in App-Support gespeichert); alle Lockfiles committen
(`package-lock.json`, `Package.resolved`; mads-seitig `Cargo.lock`).

---

## 5. Per-Verbindungs-`FsScope`-Refactor (mads-Seite, `files.rs`)

Der Sicherheitskern (`is_denied`, `canonicalize_allowing_missing`, `ensure_in_scope`, die
Zu-breit-Root-Ablehnung) ist **pur über `&FsScope` und ändert sich nicht**. Der Refactor betrifft nur,
*welches Root-Set eine Anfrage sieht*.

```rust
// files.rs — scope-parametrisierte inner-fns extrahieren (pub(crate)):
pub(crate) fn ensure_in_scope(scope: &FsScope, raw: &str) -> Result<PathBuf,String> { /* unverändert */ }
pub(crate) fn read_dir_inner(scope: &FsScope, path: &str)  -> Result<Vec<DirNode>,String> { /* Body von mads_read_dir */ }
pub(crate) fn read_file_inner(scope: &FsScope, path: &str) -> Result<FileRead,String> { /* Body von mads_read_file */ }
// write_file_inner / write_file_bytes_inner nehmen bereits &FsScope ✅
pub(crate) fn register_root_inner(scope: &FsScope, path: &str) -> Result<(),String> {
    // GLEICHE Breiten-Validierung wie mads_register_root (lehnt /, $HOME, <2 Segmente, System-Dirs ab)
    // + canonicalize + scope.add_root(root).
    // DARF app.fs_scope().allow_directory(..) NICHT aufrufen — das würde den prozessglobalen
    // tauri-plugin-fs-Scope (nur für den lokalen Webview-Watch) aufweiten. Netz-Clients weiten nie.
}
// FsScope::{add_root, roots} → pub(crate). FsScope ist bereits Default.
```
Bridge-Seite — ein Scope pro Socket, verschwindet beim Disconnect:
```rust
struct ConnScope { fs: FsScope, device_id: String }   // fs = FsScope::default() pro Verbindung
// Dispatch: register_root/read_dir/read_file/write_file/write_file_bytes/save|load_transcript → &conn.fs
```
Die `#[tauri::command]`-Wrapper (`mads_read_dir` …) bleiben der **lokale** Webview-Pfad am globalen
Scope; die Bridge nutzt sie **nicht**. Ein `register_root` eines Clients mutiert nur dessen
`ConnScope.fs.roots` — kann weder den Scope eines anderen Sockets noch den lokalen Webview aufweiten.
Beim Disconnect fällt `ConnScope` weg → Grants verschwinden. Genau der §9.5-Fix.

---

## 6. Sicherheitsmodell & Checkliste

**Kern-Prämisse:** Eine gekoppelte App ist **RCE-äquivalent** (kann Agenten starten = Code am Mac
ausführen, pushen, mergen). Auth + Transport-Verschlüsselung + Scope-Isolation sind der Kern, nicht
optional. Threat-Model + Checkliste aus 12+ Skills der Anthropic-Cybersecurity-Bibliothek.

**P0 — die RCE-äquivalente Grenze**
1. **`permissionMode ∈ {bypassPermissions, dontAsk}` von Remote hart ablehnen** vor `sidecar_send`.
   Höchste Wirkung — sonst werden alle Agent-Tool-Calls automatisch freigegeben.
2. **Jeden Frame authentifizieren**, nicht nur den Handshake. Validierte `device_id` beim Connect an
   `ConnScope` binden (einmal voller Argon2-Verify); Widerruf **killt laufende Sockets**.
3. **Jeden Frame in den exakten `HostMessage`-Typ deserialisieren; unbekannte Felder droppen;
   unbekannte `channel`/`type` ablehnen** vor Forward an stdin (Anti-NDJSON-Injection).
4. **`start_agent.cwd`/`repoRoot` auf bereits registrierte in-scope Roots einschränken**;
   least-privilege `allowedTools` für remote-gestartete Agenten.
5. **Per-Verbindungs-`FsScope`** (§5). Deny-First, Canonicalize-dann-Re-Deny, Prefix-Assertion,
   leere-Roots = harter Fehler, `sanitize_agent_id`, `register_root`-Breitenchecks.

**P1 — Transport- & Pairing-Krypto**
6. TLS 1.3 only; nur AES-256-GCM / ChaCha20-Poly1305; **`max_early_data_size = 0`**.
7. Leaf: SAN (mDNS-Host + LAN-IPs), `CA:FALSE`, `serverAuth`-EKU; Cert/Key persistieren (0600).
8. **SPKI-SHA256 pinnen** (nicht Leaf) auf iOS; fp über **QR/PIN** liefern (mDNS-TXT `fp` nur Hinweis);
   lautes UX bei fp-Wechsel; kein dynamisches/Netz-Pin-Fetch.
9. PIN: einmalig, 60 s TTL, ≤5 Versuche, Backoff + Lockout. Token = opaque ≥256-bit CSPRNG,
   Argon2id-gehasht in SQLite; nie in WS-URL/Query.
10. **Upgrades mit Browser-`Origin`-Header ablehnen** (Anti-CSWSH — nativer Client sendet keinen).

**P2 — Autorisierung & privilegierte Ops**
11. Privilegierte Ops (`integrate_pr`, `update_main`, `create_pr`, `shutdown`, `set_autonomy`) hinter
    Mac-seitiger Zweitbestätigung (OE-R5, an per Default).
12. **BOLA:** `agentId`/`requestId` ablehnen, die nicht zum Live-Set der Instanz gehören; generische
    Fehler (kein Existenz-Orakel).
13. Host-absolute Pfade + Secrets aus jedem an Clients gespiegelten `stderr`/Error scrubben.

**P3 — iOS-at-rest & Injection**
14. Token + SPKI im Keychain `…AfterFirstUnlockThisDeviceOnly`; nie in die Zwischenablage; gecachte
    Transcripts vom Backup ausschließen + Data-Protection.
15. **Markdown auf dem Mac sanitizen** (GitHub-Allowlist: `<script>`, `on*=`, `javascript:`/nicht-Bild-
    `data:`, `iframe`/`object`/`form` strippen). iOS-Preview: `loadHTMLString(_, baseURL: nil)`, **JS
    aus**, blockende `WKContentRuleList`, `WKNavigationDelegate` bricht jede Navigation ab, CSP
    `default-src 'none'; img-src data:; style-src 'unsafe-inline'; sandbox`. Editor-WebView: JS an,
    `script-src 'self'`, `connect-src 'none'`.
16. **Keine App-Aktion durch Modell-/Markdown-/Tool-Output automatisch ausgelöst**; `permission_request`
    = expliziter menschlicher Tap. CM6-Bridge setzt Text via Transactions, nie `innerHTML`.

**P4 — DoS, Supply-Chain, Audit**
17. Per-Verbindungs-Token-Bucket auf der `command`-Plane; Cap gleichzeitiger Verbindungen; Frame-Cap.
18. SBOM je Ecosystem (Cargo/npm/SPM) + `grype`/`cargo audit`/`npm audit` in CI; Lockfiles committen;
    Dep-Confusion-`.npmrc`-Scope-Pin falls interne Packages.
19. SQLite-Audit-Log jedes Remote-Befehls (device-id + ts); globaler „Pairing deaktivieren"-Schalter.

---

## 7. Phasenplan (Erst-PR-große Meilensteine)

Legende: **[iOS]** mads-remote-Repo · **[BR]** mads-Repo-Bridge · **[TS]** protocol/sidecar.
Reihenfolge: **Bridge zuerst** (gewählt) — P0.2 ist das kleinste wertvolle Inkrement, `wscat`-testbar.

| Phase | Meilenstein | Seite | Testbar |
|-------|-------------|-------|---------|
| **P0.1** | `request_snapshot`-Typ + Sidecar-Re-Emit-Handler | [TS] | Unit: `request_snapshot` an Sidecar-stdin → Snapshot-Nachrichten auf stdout. |
| **P0.2** ⭐ | Bridge-Skelett: rustls TLS 1.3 self-signed + `mdns-sd`-Advertise + `tokio-tungstenite`-Accept + **stdout-Tee** | [BR] | `dns-sd -B _mads-remote._tcp`; `openssl s_client` zeigt TLS 1.3; `wscat` empfängt Live-Agent-Events. |
| **P0.3** | Forward-Pfad: `send_line` extrahiert; Client-Frames gegen `HostMessage` validiert → stdin; `bypassPermissions` abgelehnt | [BR] | `wscat` sendet `poll_project` → Sidecar antwortet; `bypassPermissions` wird abgelehnt. |
| **P1.1** | Per-Conn-`ConnScope` + `*_inner`-fns; file-rpc-Dispatch (`register_root`/`read_dir`/`read_file`) | [BR] | `wscat`: in-scope read_file ok; out-of-scope denied; zweiter Socket sieht Root des ersten nicht. |
| **P1.2** | Pairing: SQLite-Device-Table, PIN/QR-Issue, Argon2-Token, per-Frame-Auth, Widerruf | [BR] | `wscat` ohne Token abgelehnt; mit Token akzeptiert; Widerruf droppt Socket. |
| **P2.1** | iOS-App-Shell: xcodegen `project.yml`, NWBrowser-Discovery-Liste, Info.plist-Keys | [iOS] | App listet den advertisenden Mac; Tap löst Local-Network-Prompt aus. |
| **P2.2** | iOS-Transport: `URLSessionWebSocketTask` + TOFU-SPKI-Pin + Keychain; Read-Loop → `InstanceStore.apply` | [iOS] | App verbindet zur Bridge, spiegelt Live-Timeline; Pin-Mismatch fail-hard. |
| **P2.3** | iOS-Pairing-UI: DataScanner-QR + PIN → Token im Keychain | [iOS] | End-to-end-Pairing gegen P1.2-Bridge; Reconnect nach Kill via `request_snapshot`. |
| **P3.1** | Command-Plane in App: send_input, start/stop agent, Permission-Antworten (nur Tap) | [iOS] | Realen Agenten vom Handy treiben; Permission-Requests brauchen Tap. |
| **P3.2** | file-rpc-Editor: CM6-Bundle in WKWebView, OpenFile-Optimistic-Concurrency, ConflictSheet | [iOS]+[BR] | `.md` editieren + speichern; parallele Mac-Änderung → Konflikt-Sheet mit 3 Aktionen. |
| **P4** | Bild-Paste (Binär-Frame OE-R6), Mac-seitige sanitized Preview, OE-R5-Bestätigungen | [iOS]+[BR]+[TS] | Bild einfügen → `assets/`-Write + inline; privilegierte Ops prompten am Mac. |
| **P5** | Hardening: Rate-Limit, Audit-DB, SBOM/CI, `max_early_data=0`, Frame-Caps, Widerruf-UI | [BR]+[iOS] | Flood-Test abgelehnt; Audit-Zeilen geschrieben; `cargo audit` clean in CI. |

---

## 8. Akzeptierte Grenzen (v1)

- **Hintergrund-Eskalationen:** Eine reine-LAN-App kann `permission_request`-Alerts **nicht**
  zustellen, wenn sie voll suspendiert ist (Socket schläft, kein Push ohne Cloud/APNs). v1 liefert
  „Notifications nur solange die App läuft" (bzw. im Kurz-Hintergrund). Echtes
  Background-Escalation würde APNs erfordern → bricht das No-Cloud-Nicht-Ziel. Rückstellbar auf später.
- **Reichweite:** rein LAN. Fern-Zugriff nur über nutzereigenes VPN, kein eigener Relay-Dienst.
- **Auth v1:** Bearer-Token (widerrufbar). **mTLS** ist die dokumentierte stärkere Aufrüstung
  (per-Frame-Auth automatisch auf TLS-Ebene, Widerruf = Zertifikat sperren) — nachrüstbar.
- **Context7:** in dieser Session nicht als MCP verbunden; Framework-Stand wurde über
  WebSearch/Apple-Docs + die Security-Skill-Bibliothek verifiziert. Bei verbundenem Context7-Connector
  jederzeit gegenprüfbar.
