import Foundation
import Security
import Testing
@testable import mads_remote

/// SPKI-Pinning gegen ein echtes, mit openssl erzeugtes P-256-self-signed-Zertifikat mit BEKANNTEM
/// SPKI-SHA256. Beweist, dass die iOS-Rekonstruktion (P-256-Präfix + EC-Point) byte-identisch zu
/// dem ist, was openssl/rcgen berechnen — also mit dem `fp` der Bridge matcht.
struct SPKIPinningTests {
    // openssl ecparam -name prime256v1 → x509; DER base64.
    static let certB64 =
        "MIIBfDCCASOgAwIBAgIUMCoJ6f0ytNL7xV5OVngLyTRdMLQwCgYIKoZIzj0EAwIwFDESMBAGA1UEAwwJ" +
        "bWFkcy10ZXN0MB4XDTI2MDcwNzIxMTI1MloXDTI2MDcwODIxMTI1MlowFDESMBAGA1UEAwwJbWFkcy10" +
        "ZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEFnmBxvXvjiIPzaBcCLmf4yHIQMzHluav2uBIRjiM" +
        "P9maQ20EsE8PJrYSzg7upKrdWn8nptsncwyZFADNs1exc6NTMFEwHQYDVR0OBBYEFHJ5zfubflpXmqBZ" +
        "Pa/PXQ/yZ2B5MB8GA1UdIwQYMBaAFHJ5zfubflpXmqBZPa/PXQ/yZ2B5MA8GA1UdEwEB/wQFMAMBAf8w" +
        "CgYIKoZIzj0EAwIDRwAwRAIgD6A+J8+pDOcZ4djYIn2nmqRDBrWH8C1prMahRx6yXWMCIAobYchGJtRp" +
        "gZgyBIRw507JmAes3qadiKYF9vDQyAMK"
    static let expectedFp = "5b5753228df0ce60ab39d1df932915871979b2b970c64e429cce2b7a0999dab2"

    private func fixtureCert() throws -> SecCertificate {
        let der = try #require(Data(base64Encoded: Self.certB64))
        return try #require(SecCertificateCreateWithData(nil, der as CFData))
    }

    @Test func computesSpkiFingerprintMatchingOpenSSL() throws {
        let cert = try fixtureCert()
        #expect(SPKIPinning.spkiSHA256Hex(of: cert) == Self.expectedFp)
    }

    @Test func matchesPinnedFingerprintCaseInsensitive() throws {
        let cert = try fixtureCert()
        #expect(SPKIPinning.matches(certificate: cert, pinnedFingerprintHex: Self.expectedFp))
        #expect(SPKIPinning.matches(certificate: cert, pinnedFingerprintHex: Self.expectedFp.uppercased()))
    }

    @Test func rejectsWrongFingerprint() throws {
        let cert = try fixtureCert()
        #expect(!SPKIPinning.matches(certificate: cert, pinnedFingerprintHex: String(repeating: "0", count: 64)))
    }
}

/// Ausgehende Frames (App → mads): korrekte Envelope-Struktur.
struct OutgoingFrameTests {
    private func object(_ s: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }

    @Test func pairFrame() throws {
        let obj = try object(OutgoingFrame.pair(pin: "123456", name: "iPad"))
        #expect(obj["channel"] as? String == "pair")
        #expect(obj["pin"] as? String == "123456")
        #expect(obj["name"] as? String == "iPad")
    }

    @Test func authFrame() throws {
        let obj = try object(OutgoingFrame.auth(token: "dev.secret"))
        #expect(obj["channel"] as? String == "auth")
        #expect(obj["token"] as? String == "dev.secret")
    }

    @Test func commandWrapsHostMessage() throws {
        let obj = try object(OutgoingFrame.command(hostMessage: ["type": "poll_project"]))
        #expect(obj["channel"] as? String == "command")
        let msg = try #require(obj["msg"] as? [String: Any])
        #expect(msg["type"] as? String == "poll_project")
    }
}
