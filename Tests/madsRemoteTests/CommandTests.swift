import Foundation
import Testing
@testable import mads_remote

/// Command-Plane (P3.1): Permission-Tracking im Store + Envelope der answer_permission-Entscheidung.
@MainActor
struct CommandTests {
    @Test func permissionRequestTrackedAndDeduped() {
        let store = InstanceStore()
        let req = PermissionRequestInfo(agentId: "a", requestId: "r1", toolName: "Bash", kind: "tool")
        store.apply(.permissionRequest(req))
        #expect(store.permissions.count == 1)
        #expect(store.streams["a"]?.status == .escalation)

        store.apply(.permissionRequest(req)) // gleiche requestId → nicht doppelt
        #expect(store.permissions.count == 1)

        store.removePermission(requestId: "r1")
        #expect(store.permissions.isEmpty)
    }

    @Test func permissionResolvedClearsCardWithoutAnsweringHere() {
        let store = InstanceStore()
        let req = PermissionRequestInfo(agentId: "a", requestId: "r1", toolName: "Bash", kind: "tool")
        store.apply(.permissionRequest(req))
        #expect(store.permissions.count == 1)
        #expect(store.streams["a"]?.status == .escalation)

        // Woanders beantwortet (Mac / anderes Gerät): der Sidecar broadcastet permission_resolved —
        // die Karte muss hier verschwinden, OBWOHL dieses Gerät nicht geantwortet hat.
        store.apply(.permissionResolved(agentId: "a", requestId: "r1"))
        #expect(store.permissions.isEmpty)
        // Status wird NICHT selbst umgesetzt (kein fälschliches .running bei gestopptem Agent) — der
        // Sidecar sendet dafür ein eigenes status_update. Bis dahin bleibt der letzte Stand.
        #expect(store.streams["a"]?.status == .escalation)

        // Unbekannte requestId → kein Absturz, keine Wirkung, KEIN Geister-Stream für unbekannte agentId.
        store.apply(.permissionResolved(agentId: "ghost", requestId: "does-not-exist"))
        #expect(store.permissions.isEmpty)
        #expect(store.streams["ghost"] == nil)
    }

    @Test func permissionsOpenPrunesStaleCardsAuthoritatively() {
        let store = InstanceStore()
        store.apply(.permissionRequest(PermissionRequestInfo(agentId: "a", requestId: "r1", toolName: "Bash", kind: "tool")))
        store.apply(.permissionRequest(PermissionRequestInfo(agentId: "a", requestId: "r2", toolName: "Bash", kind: "tool")))
        store.apply(.permissionRequest(PermissionRequestInfo(agentId: "b", requestId: "r3", toolName: "Bash", kind: "tool")))
        #expect(store.permissions.count == 3)

        // Snapshot sagt: für Agent a ist nur noch r2 offen (r1 wurde verpasst-aufgelöst). b unberührt.
        store.apply(.permissionsOpen(agentId: "a", requestIds: ["r2"]))
        #expect(Set(store.permissions.map(\.requestId)) == ["r2", "r3"])

        // Leere Liste für a → alle a-Karten weg, b bleibt.
        store.apply(.permissionsOpen(agentId: "a", requestIds: []))
        #expect(store.permissions.map(\.requestId) == ["r3"])
    }

    @Test func answerPermissionDecisionEnvelope() throws {
        let frame = OutgoingFrame.command(hostMessage: [
            "type": "answer_permission", "agentId": "a", "requestId": "r",
            "decision": ["behavior": "allow"],
        ])
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        #expect(obj["channel"] as? String == "command")
        let msg = try #require(obj["msg"] as? [String: Any])
        #expect(msg["type"] as? String == "answer_permission")
        let decision = try #require(msg["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
    }

    /// Review-Fix (Finding #1/#2): schlägt das Senden der Antwort fehl (keine Verbindung), muss die
    /// Berechtigung WIEDER erscheinen (nicht still verschwinden) + ein Fehler vermerkt sein.
    @Test func answerPermissionRestoresBannerWhenSendFails() async {
        let session = InstanceSession(instance: DiscoveredInstance(testId: "x", name: "n", project: "p", fingerprint: nil))
        session.store.apply(.permissionRequest(PermissionRequestInfo(agentId: "a", requestId: "r1", toolName: "Bash", kind: "tool")))
        #expect(session.store.permissions.count == 1)

        // connection == nil → sendCommand schlägt fehl → Banner wieder da + noteError.
        await session.answerPermission(agentId: "a", requestId: "r1", allow: true)
        #expect(session.store.permissions.count == 1)
        #expect(session.store.lastError != nil)
    }

    /// Doppel-Antwort-Guard: ist die Anfrage schon weg, tut ein zweiter Aufruf nichts.
    @Test func answerPermissionIsNoOpWhenAlreadyAnswered() async {
        let session = InstanceSession(instance: DiscoveredInstance(testId: "x", name: "n", project: "p", fingerprint: nil))
        // Keine offene Permission → answerPermission darf nichts tun (kein Crash, kein Fehler-Spam).
        await session.answerPermission(agentId: "a", requestId: "nope", allow: false)
        #expect(session.store.permissions.isEmpty)
    }
}
