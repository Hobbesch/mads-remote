# Fernzugriff ausserhalb des LAN — Recherche

> Stand: 2026-09-23. Entscheidungsgrundlage, noch keine Umsetzung.
> Bezug: [`architecture.md` §6](architecture.md#6-sicherheitsmodell--checkliste) (Sicherheitsmodell),
> [§8](architecture.md#8-akzeptierte-grenzen-v1) (akzeptierte Grenzen), [`mads-bridge.md`](mads-bridge.md) (TXT-Keys).

## 1. Ausgangslage

Heute: Discovery über mDNS, Transport WSS/TLS 1.3 mit SPKI-TOFU-Pin, Auth über ein beim Pairing
ausgegebenes Geräte-Token (Argon2id, widerrufbar). Reichweite: dasselbe LAN.

Zwei Sätze aus dem bestehenden Design geben den Rahmen vor:

- **§8:** „Reichweite: rein LAN. Fern-Zugriff nur über **nutzereigenes VPN**, kein eigener
  Relay-Dienst." → Ein Overlay-Netz ist der **vorgesehene** Weg, kein Bruch der Invariante. Was
  ausgeschlossen bleibt, ist ein von mads betriebener Relay-Dienst.
- **§6, Kern-Prämisse:** „Eine gekoppelte App ist **RCE-äquivalent**." → Diese Erweiterung verschiebt
  eine RCE-äquivalente Schnittstelle aus dem LAN heraus. Das ist die eigentliche Entscheidung,
  nicht die Transport-Technik.

## 2. Was „einmal koppeln, immer wiederfinden" technisch verlangt

Drei Dinge, die heute alle an mDNS hängen:

| | Bedarf | Status |
|---|---|---|
| **Adresse** | eine Kennung, die Netzwechsel überlebt | offen — mDNS traversiert keinen Tunnel |
| **Identität** | „ist das derselbe Mac?" | **gelöst** — SPKI-Pin + Token gelten unverändert |
| **Erreichbarkeit** | der Mac sitzt hinter NAT/CGNAT | offen — braucht Hole-Punching oder Relay |

Nur Adresse und Erreichbarkeit sind zu lösen. Die Krypto-Seite trägt bereits.

## 3. Optionen im Überblick

| Option | Adresse | Erreichbarkeit | Fremd-Infrastruktur | Aufwand |
|---|---|---|---|---|
| **Tailscale** | stabile 100.x-IP | Hole-Punching + DERP | Kontroll-Ebene bei Tailscale | sehr klein |
| **Headscale** | stabile 100.x-IP | wie oben | selbst gehostet | mittel (Betrieb) |
| **iroh** | NodeId (Public Key) | QUIC-Hole-Punching + Relay | optional (DHT möglich) | gross (Transport-Umbau) |
| **WireGuard + VPS** | feste Overlay-IP | über den VPS | eigener VPS | mittel (Betrieb) |
| **Cloudflare Tunnel / Funnel** | öffentliche URL | Fremd-Edge | ja, terminiert TLS | klein — **abgelehnt**, s. u. |

## 4. Befunde im Detail

### Tailscale — pragmatisch, aber mit zwei Haken

Die **100.64.0.0/10-Adresse ist pro Gerät stabil** und bleibt gleich, egal wo das Gerät steckt, auch
beim Wechsel von WLAN auf Mobilfunk. Genau das ist der Anker für „einmal koppeln": die IP beim
Pairing merken, danach nie wieder suchen.

Zwei Haken, die die Umsetzung prägen:

1. **Nicht auf MagicDNS bauen.** Auf iOS ist die Namensauflösung seit Jahren unzuverlässig; das
   „Detect MagicDNS hostnames"-On-Demand löst das erneute Verbinden nicht aus
   ([#13799](https://github.com/tailscale/tailscale/issues/13799), offen). Die 100.x-IP umgeht das
   komplett — sie braucht kein DNS.
2. **VPN-On-Demand kostet Akku.** Einmal durch eine DNS-Abfrage ausgelöst, bleibt der Tunnel dauerhaft
   an, weil im Hintergrund ständig DNS läuft ([#7386](https://github.com/tailscale/tailscale/issues/7386),
   [#17157](https://github.com/tailscale/tailscale/issues/17157)). Für ein iPad, das ohnehin bewusst
   benutzt wird, ist „Tailscale von Hand einschalten" die ruhigere Variante.

**Lizenz — relevant für dich:** Der Personal-Plan ist ausdrücklich **nur für nicht-kommerzielle
Nutzung** („only suitable for non-commercial use"), 6 Nutzer, unbegrenzt Nutzergeräte. Tailscale stuft
anhand der E-Mail-Domain ein: eine eigene Domain wie `@medici.ch` gilt automatisch als Business und
landet im bezahlten Trial. Wenn mads ein privates Projekt ist, mit privater Adresse registrieren;
wenn es zur GmbH gehört, ist es ein bezahlter Seat — oder Headscale.

### Headscale — dieselbe Technik, Kontroll-Ebene bei dir

Spricht dasselbe Protokoll; der **offizielle** Tailscale-iOS-Client kann seit 1.38.1 auf eine
„Alternate Coordination Server URL" zeigen. Damit bleibt die Kontroll-Ebene in deiner Hand, ohne einen
eigenen Client bauen zu müssen. Preis: du betreibst und exponierst einen Server, und das Projekt
garantiert nur Kompatibilität mit den letzten zehn Client-Releases — ein Client-Update kann dich
also zum Server-Update zwingen.

### iroh 1.x — technisch die sauberste Antwort auf genau diese Frage

Eine Rust-Bibliothek, die **den öffentlichen Schlüssel zur Adresse macht**: „That key — not an IP
address — is the address." Damit ist „einmal koppeln, immer wiederfinden" nicht angebaut, sondern das
Grundprinzip. Der Schlüssel ändert sich nie, die Netzlage darunter darf beliebig wechseln.

Warum es hier besonders gut passt:

- **Beide Seiten nativ bedient.** Rust im Core; für iOS offizielle Swift-Bindings über SwiftPM
  (`IrohLib`) mit vorgebautem xcframework für Gerät, Simulator und macOS — **kein Rust-Toolchain im
  iOS-Build**. Auf iOS ist nur Network.framework zu linken.
- **Kein VPN-Profil, keine Network Extension.** Läuft als normale Bibliothek in der App. Der Nutzer
  schaltet nichts ein, es gibt kein System-VPN und keinen Akku-Dauerläufer.
- **Relay nur als Fallback**, Nutzdaten durchgehend QUIC/TLS-1.3-verschlüsselt — der Relay ist ein
  blindes Rohr. Public Relays von number 0 sind rate-limited, eigene sind möglich.
- **Discovery wahlweise ohne zentrale Instanz**: DNS-Records bei number 0 *oder* Mainline-DHT.

Preis: der Transport wird ausgetauscht — `SocketConnection` (Swift) und die Accept-Schleife in
`bridge.rs` gehen von WSS auf QUIC-Streams. Der SPKI-Pin wird durch die NodeId ersetzt (gleichwertig,
eher einfacher); das Geräte-Token samt Widerruf bleibt unverändert obendrauf.

### Cloudflare Tunnel, Funnel, ngrok — für diesen Fall falsch

Sie **veröffentlichen** einen Dienst. Ein Mesh verbindet dagegen nur deine eigenen Geräte miteinander.
Bei einem Endpunkt, der laut eigenem Threat-Model RCE-äquivalent ist, ist „im Internet erreichbar,
TLS terminiert bei einem Dritten" die falsche Risikoklasse — auch mit Access davor. Verworfen.

### WireGuard + eigener VPS

Vollständig selbst gehostet, feste Overlay-IPs, keine fremde Kontroll-Ebene. Dafür Schlüssel und
Konfiguration von Hand, ein VPS zum Betreiben und Patchen, und kein Hole-Punching: alles läuft über
den VPS. Solide, aber mehr Dauerarbeit als Headscale bei weniger Komfort.

## 5. Empfehlung: zwei Stufen

### Stufe 1 — gemerkter Endpunkt + Overlay-Netz (klein, sofort)

**Die eigentliche Arbeit ist nicht der Tunnel, sondern dass die App eine Adresse über das Pairing
hinaus behält.** Dafür gibt es seit `fcf8653` bereits die Kandidatenkette in
`InstanceSession.resolveEndpoint()` — sie muss nur einen Eintrag mehr bekommen:

1. Beim Pairing den Endpunkt mitspeichern (Keychain, neben Token und SPKI-fp).
2. Kette erweitern: TXT `addr` → TXT `host` → **gemerkter Fern-Endpunkt** → Bonjour.
3. Den QR-Code (OE-R4) um den Fern-Endpunkt ergänzen, damit das Merken beim Koppeln passiert und
   nicht als separate Einstellung.
4. Overlay: Tailscale bzw. Headscale auf Mac und iPad. Die App lernt die 100.x-IP.

Ergebnis: im WLAN unverändert schnell über die LAN-IP, ausserhalb über den Tunnel — ohne dass du in
der App etwas umschaltest. Der Aufwand liegt fast ganz auf der iOS-Seite; die Bridge lauscht ohnehin
auf allen Interfaces.

### Stufe 2 — iroh als Transport (strategisch)

Löst Adresse und Erreichbarkeit in einem Zug, ohne VPN auf dem iPad und ohne fremde Kontroll-Ebene,
und macht Stufe 1 überflüssig. Lohnt sich, wenn der Fernzugriff dauerhaft wichtig wird — als eigener
Meilenstein, nicht nebenbei.

## 6. Sicherheits-Delta — der Punkt, der nicht untergehen darf

Heute schützt das LAN faktisch mit: wer nicht im WLAN ist, kommt nicht an die Bridge. Über einen
Tunnel fällt dieser stille zweite Faktor weg. Der Blast Radius geht von „jemand in meinem WLAN" auf
„wer das Geräte-Token hat".

Was bereits trägt: Per-Frame-Auth, Widerruf killt laufende Sockets, OE-R5-Zweitbestätigung am Mac für
aussen-sichtbare Aktionen, Audit-Log.

Was dazukommen sollte:

- **Die Session soll wissen, ob sie LAN oder Fern ist**, und die Politik entsprechend verschärfen:
  OE-R5 ausnahmslos an bei Fernverbindungen (nicht abschaltbar), strengeres Rate-Limit.
- **Overlay-ACL statt Vollzugriff:** im Tailnet nur `iPad → Mac:<port>` erlauben, nicht das ganze Netz.
- Vor der Umsetzung: `docs/security/` im mads-Repo um einen Nachtrag zum Audit von 2026-07-09
  ergänzen — der bewertete ausdrücklich eine LAN-Bridge.

## 7. Vorgeschlagene Entscheidungen

| # | Frage | Vorschlag |
|---|---|---|
| **OE-R10** | Overlay-Netz | Tailscale für den Anfang; Headscale, sobald es kommerziell wird |
| **OE-R11** | Fern-Politik | OE-R5 bei Fernverbindungen erzwingen, Rate-Limit verschärfen |
| **OE-R12** | Transport langfristig | iroh evaluieren, sobald Stufe 1 im Alltag steht |

## Quellen

- [Tailscale: IP-Adressen](https://tailscale.com/kb/1033/ip-and-dns-addresses) · [Pricing](https://tailscale.com/pricing) · [Free plans](https://tailscale.com/docs/account/manage-plans/free-plans-discounts) · [VPN On Demand (iOS)](https://tailscale.com/docs/features/client/ios-vpn-on-demand)
- Tailscale-Issues [#13799](https://github.com/tailscale/tailscale/issues/13799), [#7386](https://github.com/tailscale/tailscale/issues/7386), [#17157](https://github.com/tailscale/tailscale/issues/17157)
- [Headscale: Clients](https://headscale.net/stable/about/clients/) · [juanfont/headscale](https://github.com/juanfont/headscale)
- [iroh: What is iroh?](https://docs.iroh.computer/what-is-iroh) · [Swift-Bindings](https://docs.iroh.computer/languages/swift) · [IrohLib im Swift Package Index](https://swiftpackageindex.com/n0-computer/iroh-ffi)
