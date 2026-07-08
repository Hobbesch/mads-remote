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

    func start() {
        guard browser == nil else { return }

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
            Task { @MainActor [weak self] in self?.instances = deduped }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready: self?.isBrowsing = true
                case .failed, .cancelled: self?.isBrowsing = false
                default: break
                }
            }
        }

        browser.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        browser?.cancel()
        browser = nil
        instances = []
        isBrowsing = false
    }
}
