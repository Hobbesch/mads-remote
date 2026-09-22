import Foundation

/// Eine Instanz, mit der dieses Gerät schon einmal gekoppelt war — samt der Adressen, unter denen
/// die Bridge erreichbar ist.
///
/// Der Grund für diesen Speicher: mDNS endet an der Netzgrenze. Ausserhalb des WLAN findet der
/// `NWBrowser` gar nichts, die Instanz erschiene also nicht einmal in der Liste. Gemerkt bleibt sie
/// sichtbar und verbindbar — über einen Tunnel (Tailscale & Co.) genauso wie zu Hause.
///
/// `endpoints` kommt von der Bridge selbst (`pair-reply`/`auth-reply`, Feld `endpoints`) und wird
/// bei JEDER erfolgreichen Verbindung aufgefrischt. Wechselt der Mac das Netz, lernt das Gerät die
/// neue Adresse beim nächsten Mal im WLAN von selbst.
struct KnownInstance: Codable, Sendable, Hashable, Identifiable {
    let id: String              // wie `DiscoveredInstance.id`: iid, sonst fp, sonst Service-Name
    var name: String
    var project: String
    /// HOST-Identität (SPKI-fp) = Schlüssel für Token und gepinnten Fingerprint in der Keychain.
    var fingerprint: String?
    /// „host:port", von der Bridge gemeldet, in ihrer Reihenfolge (LAN vor Overlay).
    var endpoints: [String]
    var lastSeen: Date

    /// Einen gespeicherten „host:port"-Eintrag zerlegen. Von HINTEN getrennt, damit der Port auch
    /// dann stimmt, wenn der Host selbst Doppelpunkte trägt.
    static func split(_ text: String) -> (host: String, port: UInt16)? {
        guard let colon = text.lastIndex(of: ":") else { return nil }
        let host = String(text[text.startIndex..<colon])
        guard !host.isEmpty, let port = UInt16(text[text.index(after: colon)...]) else { return nil }
        return (host, port)
    }
}

/// Persistenz der bekannten Instanzen — EIN JSON-Blob in der Keychain.
///
/// Keychain und nicht `UserDefaults`, obwohl es keine Geheimnisse sind: die Liste verrät
/// Repo-Namen und die Netz-Topologie des Macs, und sie gehört sachlich zu Token und gepinntem
/// Fingerprint, die schon dort liegen (§6 P3#14 — `AfterFirstUnlockThisDeviceOnly`, kein
/// iCloud-Sync). Ein Blob statt eines Eintrags pro Instanz, weil das Auflisten von
/// Keychain-Einträgen umständlich ist und die Liste ohnehin immer ganz gelesen wird.
enum KnownInstanceStore {
    private static let account = "known-instances"

    static func all() -> [KnownInstance] {
        guard let raw = KeychainStore.load(account: account),
              let data = raw.data(using: .utf8),
              let items = try? JSONDecoder().decode([KnownInstance].self, from: data)
        else { return [] }
        return items
    }

    static func endpoints(id: String) -> [String] {
        all().first { $0.id == id }?.endpoints ?? []
    }

    /// Eine Instanz eintragen oder auffrischen. Eine LEERE Endpunkt-Liste (alte mads-Version, die
    /// das Feld noch nicht sendet) überschreibt die gemerkte NICHT — sonst verlöre ein Reconnect
    /// gegen einen alten Mac genau die Adressen, die den Fernzugriff tragen.
    static func remember(
        id: String, name: String, project: String, fingerprint: String?, endpoints: [String]
    ) {
        var items = all()
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].name = name
            items[idx].project = project
            items[idx].fingerprint = fingerprint ?? items[idx].fingerprint
            if !endpoints.isEmpty { items[idx].endpoints = endpoints }
            items[idx].lastSeen = Date()
        } else {
            items.append(KnownInstance(
                id: id, name: name, project: project, fingerprint: fingerprint,
                endpoints: endpoints, lastSeen: Date()))
        }
        save(items)
    }

    /// Beim Entkoppeln mit aufräumen — ein Eintrag ohne Token wäre eine Karteileiche, die jedes Mal
    /// ins Pairing führt.
    static func forget(id: String) {
        save(all().filter { $0.id != id })
    }

    private static func save(_ items: [KnownInstance]) {
        guard let data = try? JSONEncoder().encode(items),
              let text = String(data: data, encoding: .utf8)
        else { return }
        KeychainStore.save(text, account: account)
    }
}
