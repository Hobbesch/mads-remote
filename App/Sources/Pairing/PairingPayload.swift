import Foundation

/// Der QR-Inhalt fürs Pairing (docs/mads-bridge.md; die Bridge generiert `pairing_qr_svg`):
/// `mads-remote://pair?pv=1&fp=<spki-hex>&pin=<pin>`. Die App scannt das, matcht den mDNS-Service
/// per `fp` und löst den `pin` ein. Pure/testbar — von Kamera/Scanner entkoppelt.
struct PairingPayload: Equatable, Sendable {
    let fingerprint: String
    let pin: String
    let protocolVersion: String?

    static let scheme = "mads-remote"

    /// Parst einen gescannten String. nil, wenn kein gültiger mads-Pairing-Payload.
    static func parse(_ raw: String) -> PairingPayload? {
        guard let comps = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.scheme == scheme,
              comps.host == "pair",
              let items = comps.queryItems
        else { return nil }

        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let fp = value("fp"), let pin = value("pin") else { return nil }
        return PairingPayload(fingerprint: fp, pin: pin, protocolVersion: value("pv"))
    }
}
