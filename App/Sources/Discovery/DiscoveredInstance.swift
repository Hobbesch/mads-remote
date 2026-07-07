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
    let endpoint: NWEndpoint

    init?(result: NWBrowser.Result) {
        guard case let .service(serviceName, _, _, _) = result.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case let .bonjour(record) = result.metadata {
            txt = record.dictionary
        }
        let f = DiscoveredInstance.fields(txt: txt, serviceName: serviceName)
        self.id = serviceName
        self.name = f.name
        self.project = f.project
        self.pid = f.pid
        self.protocolVersion = f.pv
        self.fingerprint = f.fp
        self.endpoint = result.endpoint
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
