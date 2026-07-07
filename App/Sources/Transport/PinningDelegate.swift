import Foundation
import Security

/// TOFU-SPKI-Pinning am **Session**-Delegate (nicht am Task-Delegate — sonst feuert die Challenge
/// nie; häufiger „Pinning greift nicht"-Bug). Matcht der Server-Leaf-SPKI nicht den gepinnten fp,
/// wird die Verbindung HART abgebrochen (kein „trust on mismatch").
/// `@unchecked Sendable`: einziger Zustand ist ein immutabler String.
final class PinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let pinnedFingerprintHex: String

    init(pinnedFingerprintHex: String) {
        self.pinnedFingerprintHex = pinnedFingerprintHex
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        if SPKIPinning.matches(certificate: leaf, pinnedFingerprintHex: pinnedFingerprintHex) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
