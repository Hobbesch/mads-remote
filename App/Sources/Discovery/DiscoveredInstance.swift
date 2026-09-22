import Network

/// Eine im LAN gefundene mads-Instanz (aus dem Bonjour-`_mads-remote._tcp`-Service + TXT-Record).
/// Der `endpoint` wird in P2.2 zum Verbinden (WSS) aufgelöst. Siehe docs/mads-bridge.md (TXT-Keys).
struct DiscoveredInstance: Identifiable, Hashable, Sendable {
    let id: String            // Identität DIESES PROJEKTS (TXT "iid"; Fallback fp/Service-Name)
    let name: String          // TXT "name" = owner/repo (Fallback: Service-Instanzname)
    let project: String       // TXT "project" = repoRoot-Basename
    let pid: String?          // TXT "pid"
    let protocolVersion: String?  // TXT "pv"
    let fingerprint: String?      // TXT "fp" = SPKI-Pin des HOSTS (nur Hinweis; autoritativ ist der gepinnte fp)
    let directHost: String?   // TXT "addr" = annoncierte LAN-IP (umgeht die fragile Auflösung)
    let directPort: UInt16?   // TXT "port"
    /// TXT "host" = mDNS-Hostname der Bridge. Rückfall, wenn `addr` veraltet ist: der A-Record
    /// dahinter bleibt bei einem IP-Wechsel des Macs aktuell, die TXT-Kopie `addr` nicht. Ältere
    /// mads-Versionen senden den Key nicht (dokumentiert, aber nie implementiert) → `bridgeHostname`.
    let advertisedHost: String?
    let serviceName: String   // roher Bonjour-Instanzname ("mads-<iid>" neu / "mads-<fp12>"/"mads-<pid>" alt)
    let txtInstanceId: String?    // TXT "iid" = Projekt-Identität (fehlt bei älteren mads-Versionen)
    let endpoint: NWEndpoint

    /// Schlüssel, unter dem Token + gepinnter Fingerprint in der Keychain liegen. Das ist die
    /// HOST-Identität (SPKI-fp), NICHT die Projekt-Identität: seit mads Zertifikat und Geräte-DB
    /// global hält, gilt eine Kopplung für alle Projekte desselben Macs. Fällt auf `id` zurück,
    /// solange kein fp bekannt ist (dann scheitert `start()` ohnehin an der fehlenden Pin-Quelle).
    var credentialKey: String { fingerprint ?? id }

    init?(result: NWBrowser.Result) {
        guard case let .service(serviceName, _, _, _) = result.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case let .bonjour(record) = result.metadata {
            txt = record.dictionary
        }
        let f = DiscoveredInstance.fields(txt: txt, serviceName: serviceName)
        // Stabile Identität = `iid` (Hash des Repo-Roots): überlebt mads-Neustarts UND unterscheidet
        // parallel offene Projekte, deren SPKI-fp seit der Host-Umstellung identisch ist. Ältere
        // mads-Versionen kennen `iid` nicht → dann wie bisher der fp, sonst der Service-Name.
        self.id = f.iid ?? f.fp ?? serviceName
        self.name = f.name
        self.project = f.project
        self.pid = f.pid
        self.protocolVersion = f.pv
        self.fingerprint = f.fp
        self.directHost = txt["addr"].flatMap { $0.isEmpty ? nil : $0 }
        self.directPort = txt["port"].flatMap { UInt16($0) }
        self.advertisedHost = txt["host"].flatMap { $0.isEmpty ? nil : $0 }
        self.serviceName = serviceName
        self.txtInstanceId = f.iid
        self.endpoint = result.endpoint
    }

    /// Servicename folgt dem stabilen Schema `mads-<iid>` (bzw. `mads-<fp[0..<12]>` bei älteren
    /// mads-Versionen)? So lässt sich der LEBENDE Eintrag von veralteten pid-benannten
    /// Karteileichen unterscheiden.
    var isStablyNamed: Bool {
        if let iid = txtInstanceId, serviceName == "mads-\(iid)" { return true }
        guard let fp = fingerprint, fp.count >= 12 else { return false }
        return serviceName == "mads-\(fp.prefix(12))"
    }

    /// Wie aktuell ist dieser Eintrag? Höher schlägt niedriger, wenn zwei Einträge dieselbe Instanz
    /// meinen. Ein `iid` sendet nur die aktuelle mads-Version, ein stabiler Service-Name spricht
    /// gegen eine pid-benannte Karteileiche.
    var freshnessRank: Int { (txtInstanceId != nil ? 2 : 0) + (isStablyNamed ? 1 : 0) }

    /// Mehrere Bonjour-Einträge derselben Instanz zu EINEM entdoppeln, in zwei Stufen.
    ///
    /// Stufe 1 fasst zusammen, was dieselbe `id` trägt (mehrere Interfaces, mehrere Announcements).
    ///
    /// Stufe 2 fasst zusammen, was auf denselben `host:port` zeigt. Das braucht es für Karteileichen
    /// einer ÄLTEREN mads-Version, die ein hart beendeter Vorgänger im mDNS-Cache hinterlassen hat:
    /// die tragen kein `iid` und den damaligen, projekt-eigenen Fingerprint, also eine andere `id` —
    /// Stufe 1 sieht sie als eigene Instanz. Sichtbar wird das als Doppel-Eintrag, von dem nur einer
    /// verbindet: der veraltete Fingerprint passt nicht mehr zum Zertifikat, das der Server
    /// ausliefert, und der Pin schlägt fehl. Einträge ohne annoncierte Adresse gehen unangetastet
    /// durch, sonst verschwänden Instanzen, deren TXT-Record noch unvollständig ist.
    static func dedupePreferringLive(_ items: [DiscoveredInstance]) -> [DiscoveredInstance] {
        var byId: [String: DiscoveredInstance] = [:]
        for item in items {
            guard let existing = byId[item.id] else { byId[item.id] = item; continue }
            // Ersetzen nur, wenn der neue stabil benannt ist und der bestehende nicht (sonst halten).
            if item.isStablyNamed && !existing.isStablyNamed { byId[item.id] = item }
        }

        var byEndpoint: [String: DiscoveredInstance] = [:]
        var withoutEndpoint: [DiscoveredInstance] = []
        for item in byId.values {
            guard let host = item.directHost, let port = item.directPort else {
                withoutEndpoint.append(item)
                continue
            }
            let key = "\(host):\(port)"
            guard let existing = byEndpoint[key] else { byEndpoint[key] = item; continue }
            if item.freshnessRank > existing.freshnessRank { byEndpoint[key] = item }
        }
        return Array(byEndpoint.values) + withoutEndpoint
    }

    /// Pure TXT→Felder-Abbildung — von `NWBrowser` entkoppelt und damit unit-testbar.
    static func fields(
        txt: [String: String],
        serviceName: String
    ) -> (name: String, project: String, pid: String?, pv: String?, fp: String?, iid: String?) {
        let name = txt["name"].flatMap { $0.isEmpty ? nil : $0 } ?? serviceName
        let nonEmpty: (String) -> String? = { txt[$0].flatMap { $0.isEmpty ? nil : $0 } }
        return (name, txt["project"] ?? "", txt["pid"], txt["pv"], nonEmpty("fp"), nonEmpty("iid"))
    }
}

#if DEBUG
extension DiscoveredInstance {
    /// Nur für Tests: konstruiert eine Instanz ohne `NWBrowser.Result`.
    init(testId: String, name: String, project: String, fingerprint: String?, serviceName: String? = nil,
         instanceId: String? = nil, host: String? = nil, port: UInt16? = nil, advertisedHost: String? = nil) {
        self.id = testId
        self.name = name
        self.project = project
        self.pid = nil
        self.protocolVersion = nil
        self.fingerprint = fingerprint
        self.directHost = host
        self.directPort = port
        self.advertisedHost = advertisedHost
        self.serviceName = serviceName ?? testId
        self.txtInstanceId = instanceId
        self.endpoint = .hostPort(host: "127.0.0.1", port: 1)
    }
}
#endif
