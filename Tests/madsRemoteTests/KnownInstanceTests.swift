import Foundation
import Testing
@testable import mads_remote

/// Der Speicher, der den Fernzugriff trägt: ausserhalb des WLAN gibt es weder TXT-Record noch
/// Bonjour — nur was hier steht, führt noch zum Mac.
struct KnownInstanceTests {

    // MARK: - „host:port" zerlegen

    @Test func splitsHostAndPort() {
        let parsed = KnownInstance.split("100.101.102.103:53154")
        #expect(parsed?.host == "100.101.102.103")
        #expect(parsed?.port == 53154)
    }

    /// Von HINTEN getrennt: ein Host mit Doppelpunkt darf den Port nicht verfälschen.
    @Test func splitsAtTheLastColon() {
        let parsed = KnownInstance.split("fd7a:115c::1:443")
        #expect(parsed?.host == "fd7a:115c::1")
        #expect(parsed?.port == 443)
    }

    /// Kaputte Einträge fallen durch, statt eine unsinnige Adresse zu erzeugen, die dann in den
    /// Anklopf-Timeout läuft.
    @Test func rejectsMalformedEndpoints() {
        #expect(KnownInstance.split("10.0.0.24") == nil)          // kein Port
        #expect(KnownInstance.split(":53154") == nil)             // kein Host
        #expect(KnownInstance.split("10.0.0.24:daneben") == nil)  // Port keine Zahl
        #expect(KnownInstance.split("10.0.0.24:99999") == nil)    // > UInt16
        #expect(KnownInstance.split("") == nil)
    }

    // MARK: - Liste vereinen

    /// Eine gemerkte Instanz, die gerade NICHT im Netz steht, muss trotzdem in der Liste stehen —
    /// sonst käme man unterwegs gar nicht erst zum Verbindungsversuch.
    @Test func rememberedInstanceAppearsWhenNotDiscovered() {
        let merged = DiscoveredInstance.mergingKnown([], known: [
            KnownInstance(id: "iid-1", name: "Hobbesch/mads", project: "mads",
                          fingerprint: "abc", endpoints: ["100.64.0.5:53154"], lastSeen: Date()),
        ])
        #expect(merged.count == 1)
        #expect(merged[0].name == "Hobbesch/mads")
        #expect(merged[0].isDiscovered == false)
    }

    /// Dieselbe Instanz darf nicht doppelt erscheinen — und der LIVE-Eintrag gewinnt, weil nur er
    /// TXT-Record und Bonjour-Endpunkt mitbringt.
    @Test func discoveredWinsOverRemembered() {
        let live = DiscoveredInstance(
            testId: "iid-1", name: "Hobbesch/mads", project: "mads", fingerprint: "abc",
            host: "10.0.0.24", port: 53154)
        let merged = DiscoveredInstance.mergingKnown([live], known: [
            KnownInstance(id: "iid-1", name: "Alter Name", project: "mads",
                          fingerprint: "abc", endpoints: ["100.64.0.5:53154"], lastSeen: Date()),
        ])
        #expect(merged.count == 1)
        #expect(merged[0].directHost == "10.0.0.24")   // der Live-Eintrag
        #expect(merged[0].name == "Hobbesch/mads")
    }

    @Test func mergedListIsSortedByName() {
        let live = DiscoveredInstance(testId: "iid-z", name: "Zebra", project: "z", fingerprint: "z")
        let merged = DiscoveredInstance.mergingKnown([live], known: [
            KnownInstance(id: "iid-a", name: "Anton", project: "a", fingerprint: "a",
                          endpoints: [], lastSeen: Date()),
        ])
        #expect(merged.map(\.name) == ["Anton", "Zebra"])
    }

    // MARK: - Persistenz

    /// Merken, wiederfinden, aufräumen. Vor allem: eine LEERE Endpunkt-Liste (alte mads-Version,
    /// die das Feld nicht sendet) darf die gemerkten Adressen NICHT löschen — sonst verlöre ein
    /// Reconnect gegen einen alten Mac genau das, was den Fernzugriff trägt.
    @Test func emptyEndpointsDoNotWipeRemembered() {
        let id = "test-\(UUID().uuidString)"
        defer { KnownInstanceStore.forget(id: id) }

        KnownInstanceStore.remember(
            id: id, name: "A", project: "p", fingerprint: "fp", endpoints: ["10.0.0.24:1234"])
        #expect(KnownInstanceStore.endpoints(id: id) == ["10.0.0.24:1234"])

        KnownInstanceStore.remember(id: id, name: "A", project: "p", fingerprint: "fp", endpoints: [])
        #expect(KnownInstanceStore.endpoints(id: id) == ["10.0.0.24:1234"])

        KnownInstanceStore.remember(
            id: id, name: "A", project: "p", fingerprint: "fp", endpoints: ["100.64.0.5:1234"])
        #expect(KnownInstanceStore.endpoints(id: id) == ["100.64.0.5:1234"])
    }

    @Test func forgettingRemovesTheEntry() {
        let id = "test-\(UUID().uuidString)"
        KnownInstanceStore.remember(id: id, name: "A", project: "p", fingerprint: nil, endpoints: ["a:1"])
        KnownInstanceStore.forget(id: id)
        #expect(KnownInstanceStore.endpoints(id: id).isEmpty)
    }
}

/// Die Naht zum Mac: was `bridge.rs` in `pair-reply`/`auth-reply` schreibt, muss hier ankommen.
struct EndpointWireTests {

    @Test func authReplyCarriesEndpoints() {
        let frame = #"{"channel":"auth-reply","ok":true,"deviceId":"d1","endpoints":["10.0.0.24:53154","100.64.0.5:53154"]}"#
        let wf = WireFrame.decode(frame)
        #expect(wf?.ok == true)
        #expect(wf?.endpoints == ["10.0.0.24:53154", "100.64.0.5:53154"])
    }

    @Test func pairReplyCarriesEndpoints() {
        let frame = #"{"channel":"pair-reply","ok":true,"token":"t","deviceId":"d1","endpoints":["10.0.0.24:53154"]}"#
        let wf = WireFrame.decode(frame)
        #expect(wf?.token == "t")
        #expect(wf?.endpoints == ["10.0.0.24:53154"])
    }

    /// Eine ältere mads-Version sendet das Feld nicht — das Frame muss trotzdem durchgehen, sonst
    /// scheiterte die Anmeldung an einem Mac, der schlicht noch nicht aktualisiert ist.
    @Test func replyWithoutEndpointsStillDecodes() {
        let wf = WireFrame.decode(#"{"channel":"auth-reply","ok":true,"deviceId":"d1"}"#)
        #expect(wf?.ok == true)
        #expect(wf?.endpoints == nil)
    }
}
