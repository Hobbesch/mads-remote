import Foundation
import Security

/// Keychain-Speicher für Geräte-Token + gepinnten SPKI-Fingerprint (docs/architecture.md §3a,
/// §6 P3#14). Der Schlüssel ist die HOST-Identität (SPKI-fp), nicht das einzelne Projekt: mads hält
/// Zertifikat und Geräte-DB global, eine Kopplung gilt daher für alle Projekte desselben Macs. `AfterFirstUnlockThisDeviceOnly`: Reconnect im gesperrten Hintergrund möglich,
/// kein iCloud-Sync/Backup-Transfer. Klartext-Token liegt NIE außerhalb der Keychain.
enum KeychainStore {
    private static let service = "com.powerblox.mads-remote"

    // MARK: pro-Instanz-Convenience

    /// `false`, wenn der Token NICHT persistiert werden konnte. Der Aufrufer MUSS das melden:
    /// still weiterlaufen hieße, dass die Sitzung zwar live wird, beim nächsten Verbinden aber
    /// wieder ein Pairing verlangt — genau das Symptom, das ohne diese Rückmeldung unerklärlich war.
    @discardableResult
    static func saveCredentials(instanceId: String, token: String, fingerprint: String) -> Bool {
        let tokenSaved = save(token, account: "token:\(instanceId)")
        _ = save(fingerprint, account: "fp:\(instanceId)")
        return tokenSaved
    }
    static func token(instanceId: String) -> String? { load(account: "token:\(instanceId)") }
    static func pinnedFingerprint(instanceId: String) -> String? { load(account: "fp:\(instanceId)") }
    static func forget(instanceId: String) {
        delete(account: "token:\(instanceId)")
        delete(account: "fp:\(instanceId)")
    }
    /// Nur den (z. B. serverseitig widerrufenen) Token verwerfen — der gepinnte Server-Fingerprint
    /// bleibt (Cert unverändert) → beim Reconnect fehlt nur der Token → die App geht ins Pairing.
    static func forgetToken(instanceId: String) { delete(account: "token:\(instanceId)") }

    // MARK: SecItem-Kern

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary) // idempotent überschreiben
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
