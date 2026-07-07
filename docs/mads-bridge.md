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
