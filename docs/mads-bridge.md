# Die mads-seitige Remote-Bridge

> Die Bridge lebt **nicht in diesem Repo**, sondern im [mads](https://github.com/Hobbesch/mads)-Repo
> (Rust-Core, `src-tauri`). Dieses Dokument hält die Schnittstelle fest, damit die iOS-App und die
> Bridge denselben Vertrag sprechen. Umsetzungs-Details & Entscheidungen: [`architecture.md`](architecture.md).

## Wo im mads-Repo

| Datei | Änderung |
|-------|----------|
| `src-tauri/src/bridge.rs` | **Neu** — WSS-Server (`tokio-tungstenite`), mDNS-Advertise (`mdns-sd`), rustls-TLS-1.3, per-Verbindungs-Dispatch, Pairing/Auth (SQLite + Argon2). |
| `src-tauri/src/files.rs` | `*_inner`-fns extrahieren + `pub(crate)`; `FsScope::{add_root,roots}` → `pub(crate)`. **Kein** Sicherheitslogik-Change (siehe `architecture.md` §5). |
| `src-tauri/src/sidecar.rs` | stdout-Loop teet Zeilen an einen Broadcast-Channel; `send_line` extrahieren (Command-Forward). |
| `src-tauri/src/lib.rs` | `mod bridge`; Bridge/Device-State managen; WSS + mDNS in `.setup()` starten. |
| `shared/protocol.ts` | `RequestSnapshotMsg extends BaseMsg { type: "request_snapshot" }` in die `HostMessage`-Union. |
| Node-Sidecar | `request_snapshot`-Handler → aktuellen Stand re-emittieren. |

## Protokoll über die Leitung (Envelope)

Ein WSS-Kanal pro Instanz, Text-Frames (je Frame = eine JSON-Nachricht), plus Binär-Frames für
`write_file_bytes` (per `id` korreliert). Vier logische Ebenen über `channel`:

```jsonc
{ "v": 1, "id": "uuid", "ts": 0, "channel": "command",         "msg": { "type": "send_input", "...": "..." } }  // App → mads (rohe HostMessage)
{ "v": 1, "id": "...",  "ts": 0, "channel": "event",           "msg": { "type": "agent_event", "...": "..." } } // mads → App (rohe SidecarMessage)
{ "v": 1, "id": "...",  "ts": 0, "channel": "snapshot",        "msg": { "...": "..." } }                        // mads → App (Ist-Zustand)
{ "v": 1, "id": "req1", "ts": 0, "channel": "file-rpc",        "op": "read_file", "args": { "path": "..." } }   // beide
{ "v": 1, "id": "req1", "ts": 0, "channel": "file-rpc-reply",  "ok": true, "result": { "...": "..." } }         // beide
```

Alle `msg`-Payloads sind die **unveränderten** `HostMessage`/`SidecarMessage`-Typen aus
`shared/protocol.ts`. Die Bridge parst sie nicht — sie validiert nur `channel`/`type` und forwarded
roh (siehe Sicherheits-Checkliste P0.3).

## Discovery (mDNS TXT-Record)

Service `_mads-remote._tcp`, ein Service pro Instanz, TXT-Keys:

| Key | Inhalt |
|-----|--------|
| `name` | `owner/repo` |
| `host` | Hostname |
| `pid` | Prozess-ID |
| `project` | `repoRoot`-Basename |
| `pv` | `PROTOCOL_VERSION` |
| `fp` | TLS-SPKI-Fingerprint (nur **Hinweis** — autoritativ ist der beim Pairing gepinnte fp) |

## Implementierungs-Status (mads-Repo, Branch `feat/remote-bridge`)

| Phase | Stand | Was |
|-------|-------|-----|
| **P0.1** | ✅ | `request_snapshot`-HostMessage + Orchestrator-Re-Emit (`shared/protocol.ts`, `sidecar/src/orchestrator.ts`). |
| **P0.2** | ✅ | Bridge-Skelett `src-tauri/src/bridge.rs`: TLS 1.3 (self-signed, SPKI-TOFU) + mDNS-Advertise + WSS-Accept + roher stdout-Tee. Read-only Live-Mirror. |
| **P0.3** | ✅ | Command-Forward: `validate_command()` erzwingt Kanal `command` + `HostMessage`-Typ-Allowlist, lehnt `bypassPermissions`/`dontAsk` hart ab (RCE-Schutz), re-serialisiert kanonisch (Anti-NDJSON-Injection) → `send_line` (stdin). 16 Rust-Tests grün. |
| **P1.1** | ✅ | Per-Verbindungs-`FsScope` (§9.5-Fix) + file-rpc-Dispatch (`register_root`/`read_dir`/`read_file`) mit `file-rpc-reply`. Schreib-Ops folgen mit dem Editor (P3.2). `files.rs`-Sicherheitskern unverändert. 21 Rust-Tests grün. |
| **P1.2** | ⏳ | Pairing (PIN/QR) + Argon2-Token (SQLite) + per-Frame-Auth + Widerruf. |

> **Sicherheits-Gate:** Die Bridge läuft nur mit **`MADS_REMOTE_BRIDGE=1`**, weil sie bis
> einschließlich P0.2 **noch auth-los** ist. Der stdout-Tee selbst ist immer aktiv, aber ohne
> laufende Bridge ohne Empfänger (kein Overhead, kein Netz-Exposure).

### Manuelle Abnahme P0.2 (am Mac)

```bash
MADS_REMOTE_BRIDGE=1 npm run tauri dev        # oder die installierte .app mit gesetzter Env-Var
dns-sd -B _mads-remote._tcp                    # Service erscheint im LAN
openssl s_client -connect <host>:<port>        # zeigt TLS 1.3 + self-signed cert
wscat --no-check -c wss://<host>:<port>         # empfängt Live-Agent-Events (roher NDJSON-Tee)
```

Automatisiert verifiziert (ohne GUI): `cargo test --lib` — `tee_reaches_tls_ws_client`
(TLS-1.3-Handshake + WSS + Tee end-to-end) und `advertise_starts_or_is_sandboxed`.
