import Network
import Observation

/// Bonjour-Discovery der mads-Instanzen (`_mads-remote._tcp`) via `NWBrowser` (docs/architecture.md
/// §3a). Beim ersten `start()` löst iOS den Local-Network-Berechtigungs-Prompt aus.
@Observable
@MainActor
final class InstanceBrowser {
    private(set) var instances: [DiscoveredInstance] = []
    private(set) var isBrowsing = false

    private var browser: NWBrowser?
    /// Soll überhaupt gesucht werden? Trennt „gerade kein Browser da" von „bewusst gestoppt" —
    /// sonst weckt ein eingeplanter Neustart nach `stop()` die Suche wieder auf.
    private var wantsBrowsing = false
    /// Zählt die Browser-Generationen. Ein abgelöster Browser darf `instances` nicht mehr
    /// überschreiben: seine Callbacks können nach `cancel()` noch unterwegs sein und würden der
    /// frischen Liste den alten Stand überbügeln.
    private var generation = 0

    func start() {
        wantsBrowsing = true
        guard browser == nil else { return }

        generation += 1
        let gen = generation

        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: "_mads-remote._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            // Handler läuft auf der Browser-Queue → geparst, per Fingerprint entdoppelt (mehrere
            // Bonjour-Einträge derselben Instanz nach Neustarts → ein Eintrag) und auf den MainActor
            // gehoben.
            let parsed = results.compactMap(DiscoveredInstance.init(result:))
            let deduped = DiscoveredInstance.dedupePreferringLive(parsed)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                self.instances = deduped
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                switch state {
                case .ready:
                    self.isBrowsing = true
                case .failed:
                    // Ein fehlgeschlagener Browser erholt sich NICHT von selbst (Apple: cancel +
                    // neu anlegen), und `start()` hält ihn für lebendig, solange `browser != nil`.
                    // Ohne diesen Neustart bleibt die Liste stumm auf dem Stand von vorhin stehen.
                    self.isBrowsing = false
                    self.scheduleRestart()
                case .cancelled:
                    self.isBrowsing = false
                default:
                    break
                }
            }
        }

        browser.start(queue: .global(qos: .userInitiated))
    }

    /// Suche neu aufsetzen. Nötig, wenn die App aus dem Hintergrund zurückkommt: iOS hält einen
    /// `NWBrowser` über eine Suspendierung hinweg nicht am Leben, meldet das aber nicht zwingend als
    /// `failed` — der Browser liefert einfach nichts mehr nach. Sichtbar wird das als Liste, in der
    /// eine längst laufende Instanz fehlt (oder eine beendete noch steht).
    ///
    /// `instances` wird bewusst NICHT geleert: der frische Browser braucht bis zu seinem ersten
    /// Ergebnissatz ein paar hundert Millisekunden, die Liste würde sonst bei jedem App-Wechsel
    /// sichtbar leer aufblitzen.
    func restart() {
        browser?.cancel()
        browser = nil
        start()
    }

    func stop() {
        wantsBrowsing = false
        generation += 1
        browser?.cancel()
        browser = nil
        instances = []
        isBrowsing = false
    }

    /// Nach einem Fehlschlag mit Abstand neu starten, damit ein dauerhaft fehlschlagender Zustand
    /// (kein WLAN, Local-Network-Erlaubnis entzogen) keine Neustart-Schleife dreht.
    private func scheduleRestart() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.wantsBrowsing else { return }
            self.restart()
        }
    }
}
