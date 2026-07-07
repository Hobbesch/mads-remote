import Foundation

/// Baut die ausgehenden WS-Text-Frames (App → mads) gemäß Envelope-Vertrag (docs/mads-bridge.md).
enum OutgoingFrame {
    /// Pairing: einmaligen PIN einlösen.
    static func pair(pin: String, name: String) -> String {
        json(["channel": "pair", "pin": pin, "name": name])
    }

    /// Re-Auth mit bestehendem Geräte-Token.
    static func auth(token: String) -> String {
        json(["channel": "auth", "token": token])
    }

    /// Wickelt eine rohe HostMessage (als JSON-Objekt) in den `command`-Envelope.
    static func command(hostMessage: [String: Any]) -> String {
        json(["v": 1, "channel": "command", "msg": hostMessage])
    }

    /// file-rpc-Request (P3): `{ channel:"file-rpc", id, op, args }`.
    static func fileRPC(id: String, op: String, args: [String: Any]) -> String {
        json(["v": 1, "channel": "file-rpc", "id": id, "op": op, "args": args])
    }

    private static func json(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else { return "{}" }
        return s
    }
}
