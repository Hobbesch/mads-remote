import Foundation
import Network

/// Kurzer TCP-Anklopf-Test auf `host:port`.
///
/// Nötig, weil die vom Mac annoncierte LAN-IP (TXT `addr`) VERALTEN kann: die Bridge schreibt sie
/// einmal beim Start des Prozesses (`advertise()` in `bridge.rs`) und zieht sie bei einem Netz-
/// oder IP-Wechsel des Macs nicht nach — der mDNS-A-Record dagegen bleibt über `enable_addr_auto()`
/// aktuell. Eine tote Adresse in einem FREMDEN Subnetz antwortet nicht einmal mit RST: ohne diesen
/// Test hing der Verbindungsaufbau stumm bis zum 8-s-Watchdog und meldete „Nicht verbunden",
/// obwohl die Instanz unter ihrem Hostnamen die ganze Zeit erreichbar war.
enum TCPProbe {

    /// `true`, wenn binnen `timeoutSeconds` eine TCP-Verbindung zustande kommt. Es wird NICHTS
    /// gesendet und der Socket sofort wieder geschlossen — der Server sieht nur einen kurz
    /// geöffneten Connect, keinen Frame und keine Auth.
    static func reachable(host: String, port: UInt16, timeoutSeconds: Int = 2) async -> Bool {
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else { return false }

        // `connectionTimeout` deckt genau den hier interessanten Fall ab: Adresse im fremden Subnetz,
        // niemand antwortet. Ohne ihn liefe der Connect in den langen System-Default.
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = timeoutSeconds
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: nil, tcp: tcp))

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = OnceGuard()
            let finish: @Sendable (Bool) -> Void = { value in
                guard once.claim() else { return }
                conn.cancel()
                cont.resume(returning: value)
            }

            // Zweiter Riegel, falls `connectionTimeout` nicht greift (Zustand bleibt in `.preparing`
            // hängen): ohne ihn würde die Continuation nie resumed und der Aufrufer ewig warten.
            let timeout = Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                finish(false)
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    timeout.cancel()
                    finish(true)
                case .failed, .cancelled:
                    timeout.cancel()
                    finish(false)
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Einmal-Guard, damit die Continuation garantiert genau einmal resumed wird — Timeout und
    /// Zustandswechsel können gleichzeitig eintreffen.
    private final class OnceGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }
}
