import Foundation

/// Die äußere Hülle über der Leitung (docs/mads-bridge.md): `{ v, id, ts, channel, msg?, … }`.
/// Für P2.2 decodieren wir den `event`/`snapshot`-Kanal (msg = SidecarMessage) und die
/// Pairing-/Auth-Antworten (ok/token/deviceId/error). file-rpc-reply folgt in P3.
struct WireFrame: Decodable, Sendable {
    let channel: String?
    let id: String?        // Korrelation für file-rpc-reply
    let msg: SidecarMessage?
    let ok: Bool?
    let token: String?
    let deviceId: String?
    let error: String?

    static func decode(_ text: String) -> WireFrame? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WireFrame.self, from: data)
    }
}
