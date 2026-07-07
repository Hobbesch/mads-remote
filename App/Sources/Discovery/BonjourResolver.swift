import Foundation
import Network

/// Löst einen Bonjour-`NWEndpoint` (Service) zu `host:port` auf, indem kurz eine `NWConnection`
/// aufgebaut und `currentPath.remoteEndpoint` gelesen wird. Nötig, weil `URLSessionWebSocketTask`
/// eine URL (nicht einen Bonjour-Endpoint) braucht. Der aufgelöste Host ist i. d. R. `*.local`
/// (mDNS) oder eine LAN-IP — beides für die WSS-URL brauchbar (das SPKI-Pinning ignoriert SNI/SAN).
enum BonjourResolver {
    /// Einmal-Guard, damit die Continuation garantiert genau einmal resumed wird.
    private final class OnceGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    static func resolve(_ endpoint: NWEndpoint) async -> (host: String, port: UInt16)? {
        await withCheckedContinuation { (cont: CheckedContinuation<(host: String, port: UInt16)?, Never>) in
            let conn = NWConnection(to: endpoint, using: .tcp)
            let guardOnce = OnceGuard()

            let finish: @Sendable ((host: String, port: UInt16)?) -> Void = { value in
                guard guardOnce.claim() else { return }
                conn.cancel()
                cont.resume(returning: value)
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = conn.currentPath?.remoteEndpoint {
                        finish((host: hostString(host), port: port.rawValue))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _): return name
        case .ipv4(let addr): return "\(addr)"
        case .ipv6(let addr): return "[\(addr)]" // IPv6 in URLs in eckigen Klammern
        @unknown default: return ""
        }
    }
}
