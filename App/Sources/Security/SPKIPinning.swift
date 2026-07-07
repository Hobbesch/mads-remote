import CryptoKit
import Foundation
import Security

/// SPKI-Pinning (TOFU) für den self-signed TLS-Server der Bridge. Der gepinnte Wert ist
/// `SHA-256(SubjectPublicKeyInfo)` — exakt der `fp`, den mads im TXT/QR liefert (Rust:
/// rcgen `subject_public_key_info()`), sodass Leaf-Rotation ohne Neu-Pairing möglich bleibt.
enum SPKIPinning {
    /// ASN.1-SubjectPublicKeyInfo-Präfix für EC **P-256** (prime256v1). Die Bridge nutzt rcgen mit
    /// ECDSA P-256 (Default). `SecKeyCopyExternalRepresentation` liefert den 65-Byte-uncompressed
    /// Point (0x04‖X‖Y); davorgesetzt ergibt das die vollständige SPKI-DER (byte-identisch zu
    /// rcgens `subject_public_key_info()`). Würde der Bridge-Key-Typ wechseln, müsste dieser Präfix
    /// angepasst werden (dokumentierte Annahme; per Fixture-Test gegen openssl abgesichert).
    static let p256SPKIPrefix: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
        0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ]

    /// SHA-256 des SubjectPublicKeyInfo (hex, lowercase) — nil, wenn der Key kein P-256-EC-Key ist.
    static func spkiSHA256Hex(of certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let point = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              point.count == 65
        else { return nil }
        var spki = Data(p256SPKIPrefix)
        spki.append(point)
        return SHA256.hash(data: spki).map { String(format: "%02x", $0) }.joined()
    }

    /// Leaf-SPKI gegen den erwarteten (gepinnten) fp prüfen. Der fp ist nicht geheim → ein
    /// case-insensitiver Hex-Vergleich genügt (kein Constant-Time nötig).
    static func matches(certificate: SecCertificate, pinnedFingerprintHex: String) -> Bool {
        guard let actual = spkiSHA256Hex(of: certificate) else { return false }
        return actual.caseInsensitiveCompare(pinnedFingerprintHex) == .orderedSame
    }
}
