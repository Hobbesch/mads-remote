import Network

/// Eine im LAN gefundene mads-Instanz (aus dem Bonjour-`_mads-remote._tcp`-Service + TXT-Record).
/// Der `endpoint` wird in P2.2 zum Verbinden (WSS) aufgelöst. Siehe docs/mads-bridge.md (TXT-Keys).
struct DiscoveredInstance: Identifiable, Hashable, Sendable {
    let id: String            // Service-Instanzname (stabil pro Instanz, z. B. "mads-<pid>")
    let name: String          // TXT "name" = owner/repo (Fallback: Service-Instanzname)
    let project: String       // TXT "project" = repoRoot-Basename
    let pid: String?          // TXT "pid"
    let protocolVersion: String?  // TXT "pv"
    let fingerprint: String?      // TXT "fp" = SPKI-Pin (nur Hinweis; autoritativ ist der gepinnte fp)
    let directHost: String?   // TXT "addr" = annoncierte LAN-IP (umgeht die fragile Auflösung)
    let directPort: UInt16?   // TXT "port"
    let serviceName: String   // roher Bonjour-Instanzname ("mads-<fp12>" neu / "mads-<pid>" alt)
    let endpoint: NWEndpoint

    init?(result: NWBrowser.Result) {
        guard case let .service(serviceName, _, _, _) = result.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case let .bonjour(record) = result.metadata {
            txt = record.dictionary
        }
        let f = DiscoveredInstance.fields(txt: txt, serviceName: serviceName)
        // Stabile Identität = SPKI-Fingerprint (überlebt mads-Neustarts; der Service-Name mads-<pid>
        // ändert sich bei jedem Neustart → sonst Doppel-Einträge + erneutes Pairing). Fallback: Name.
        self.id = f.fp ?? serviceName
        self.name = f.name
        self.project = f.project
        self.pid = f.pid
        self.protocolVersion = f.pv
        self.fingerprint = f.fp
        self.directHost = txt["addr"].flatMap { $0.isEmpty ? nil : $0 }
        self.directPort = txt["port"].flatMap { UInt16($0) }
        self.serviceName = serviceName
        self.endpoint = result.endpoint
    }

    /// Servicename folgt dem stabilen fp-Schema `mads-<fp[0..<12]>` (aktuelle mads-Version)?
    /// So lässt sich der LEBENDE Eintrag von veralteten pid-benannten Karteileichen unterscheiden.
    var isFingerprintNamed: Bool {
        guard let fp = fingerprint, fp.count >= 12 else { return false }
        return serviceName == "mads-\(fp.prefix(12))"
    }

    /// Mehrere Bonjour-Einträge derselben Instanz (gleicher Fingerprint = gleiche `id`) zu EINEM
    /// entdoppeln. Bevorzugt den fp-benannten (lebenden) Eintrag; so verschwinden veraltete
    /// pid-benannte Karteileichen mit totem Port aus der Liste, sobald der lebende sichtbar ist.
    static func dedupePreferringLive(_ items: [DiscoveredInstance]) -> [DiscoveredInstance] {
        var byId: [String: DiscoveredInstance] = [:]
        for item in items {
            guard let existing = byId[item.id] else { byId[item.id] = item; continue }
            // Ersetzen nur, wenn der neue fp-benannt ist und der bestehende nicht (sonst stabil halten).
            if item.isFingerprintNamed && !existing.isFingerprintNamed { byId[item.id] = item }
        }
        return Array(byId.values)
    }

    /// Pure TXT→Felder-Abbildung — von `NWBrowser` entkoppelt und damit unit-testbar.
    static func fields(
        txt: [String: String],
        serviceName: String
    ) -> (name: String, project: String, pid: String?, pv: String?, fp: String?) {
        let name = txt["name"].flatMap { $0.isEmpty ? nil : $0 } ?? serviceName
        return (name, txt["project"] ?? "", txt["pid"], txt["pv"], txt["fp"])
    }
}

#if DEBUG
extension DiscoveredInstance {
    /// Nur für Tests: konstruiert eine Instanz ohne `NWBrowser.Result`.
    init(testId: String, name: String, project: String, fingerprint: String?, serviceName: String? = nil) {
        self.id = testId
        self.name = name
        self.project = project
        self.pid = nil
        self.protocolVersion = nil
        self.fingerprint = fingerprint
        self.directHost = nil
        self.directPort = nil
        self.serviceName = serviceName ?? testId
        self.endpoint = .hostPort(host: "127.0.0.1", port: 1)
    }
}
#endif
