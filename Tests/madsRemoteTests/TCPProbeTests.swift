import Foundation
import Testing
import Network
@testable import mads_remote

/// Der Anklopf-Test, der eine lebende Direkt-IP von einer veralteten unterscheidet. Beide Seiten
/// müssen stimmen: meldete er immer `false`, liefe jede Verbindung still über den langsameren
/// Bonjour-Weg; meldete er immer `true`, wäre die veraltete Adresse wieder ein 8-s-Hänger.
struct TCPProbeTests {

    /// Positiv: ein tatsächlich lauschender Port gilt als erreichbar.
    @Test func openPortIsReachable() async throws {
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { $0.cancel() }   // annehmen, sofort schließen — nichts sprechen
        let port = try #require(await started(listener))
        defer { listener.cancel() }

        #expect(await TCPProbe.reachable(host: "127.0.0.1", port: port))
    }

    /// Negativ: auf einem Port, den gerade niemand mehr bedient, wird nichts vorgetäuscht. Das ist
    /// der Fall, der die veraltete TXT-Adresse aussortiert (dort per Timeout statt per RST — für
    /// den Aufrufer dieselbe Antwort).
    @Test func closedPortIsNotReachable() async throws {
        // Einen echten Port zuteilen lassen und den Listener DANACH schließen: so ist garantiert
        // niemand darauf, ohne eine Portnummer zu raten.
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { $0.cancel() }   // Pflicht vor `start()`, sonst wird er nie ready
        let port = try #require(await started(listener))
        // `cancel()` ist asynchron — den Abbau ABWARTEN. Sonst nimmt der noch offene Socket den
        // Anklopf-Test an und der Test prüfte in Wahrheit gar nichts.
        await stopped(listener)

        #expect(await TCPProbe.reachable(host: "127.0.0.1", port: port, timeoutSeconds: 1) == false)
    }

    /// Ein leerer Host (TXT ohne `addr`) fällt sofort durch, statt in einen Timeout zu laufen —
    /// sonst kostete jede Instanz ohne Direkt-IP unnötig Wartezeit.
    @Test func emptyHostFailsImmediately() async {
        #expect(await TCPProbe.reachable(host: "", port: 443) == false)
    }

    /// Listener abbauen und den Abbau abwarten (`.cancelled`), mit Zeitgrenze, damit ein
    /// ausbleibendes Ereignis den Testlauf nicht hängen lässt.
    private func stopped(_ listener: NWListener) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = TestOnce()
            let finish: @Sendable () -> Void = { if once.claim() { cont.resume() } }
            listener.stateUpdateHandler = { state in
                if case .cancelled = state { finish() }
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                finish()
            }
            listener.cancel()
        }
    }

    /// Listener starten und seinen zugeteilten Port abwarten (`.ready`).
    private func started(_ listener: NWListener) async -> UInt16? {
        await withCheckedContinuation { (cont: CheckedContinuation<UInt16?, Never>) in
            let once = TestOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { cont.resume(returning: listener.port?.rawValue) }
                case .failed, .cancelled:
                    if once.claim() { cont.resume(returning: nil) }
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }
}

/// Einmal-Guard für die Test-Continuations (`.ready` kann mehrfach gemeldet werden).
private final class TestOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
