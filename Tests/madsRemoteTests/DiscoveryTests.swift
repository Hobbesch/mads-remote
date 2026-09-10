import Testing
@testable import mads_remote

/// TXT→Felder-Abbildung der Bonjour-Discovery (pure, ohne NWBrowser).
struct DiscoveryTests {
    @Test func parsesFullTxtRecord() {
        let txt = ["name": "Hobbesch/mads", "project": "mads", "pid": "4242", "pv": "1", "fp": "abcd1234", "iid": "0123456789ab"]
        let f = DiscoveredInstance.fields(txt: txt, serviceName: "mads-0123456789ab")
        #expect(f.name == "Hobbesch/mads")
        #expect(f.project == "mads")
        #expect(f.pid == "4242")
        #expect(f.pv == "1")
        #expect(f.fp == "abcd1234")
        #expect(f.iid == "0123456789ab")
    }

    /// Ältere mads-Versionen kennen `iid` noch nicht — dann bleibt der fp die Identität.
    @Test func instanceIdIsOptionalForOlderHosts() {
        let f = DiscoveredInstance.fields(txt: ["fp": "abcd1234"], serviceName: "mads-abcd1234")
        #expect(f.iid == nil)
        #expect(f.fp == "abcd1234")
    }

    @Test func fallsBackToServiceNameWhenTxtMissing() {
        let f = DiscoveredInstance.fields(txt: [:], serviceName: "mads-999")
        #expect(f.name == "mads-999")
        #expect(f.project == "")
        #expect(f.pid == nil)
        #expect(f.fp == nil)
        #expect(f.iid == nil)
    }

    @Test func emptyNameFallsBackToServiceName() {
        let f = DiscoveredInstance.fields(txt: ["name": "", "project": "p"], serviceName: "mads-1")
        #expect(f.name == "mads-1")
        #expect(f.project == "p")
    }

    // MARK: - Dedup per Fingerprint (Karteileichen-Sammlung nach Neustarts)

    @Test func dedupesByFingerprintPreferringStableName() {
        let fp = String(repeating: "a", count: 64)
        let stale = DiscoveredInstance(testId: fp, name: "mads", project: "p", fingerprint: fp, serviceName: "mads-55873")
        let live = DiscoveredInstance(testId: fp, name: "mads", project: "p", fingerprint: fp, serviceName: "mads-\(fp.prefix(12))")
        // Reihenfolge egal: der fp-benannte (lebende) gewinnt.
        for input in [[stale, live], [live, stale]] {
            let out = DiscoveredInstance.dedupePreferringLive(input)
            #expect(out.count == 1)
            #expect(out.first?.serviceName == "mads-\(fp.prefix(12))")
        }
    }

    @Test func dedupeKeepsDistinctFingerprintsSeparate() {
        let a = DiscoveredInstance(testId: "fpA", name: "A", project: "p", fingerprint: "fpA", serviceName: "mads-1")
        let b = DiscoveredInstance(testId: "fpB", name: "B", project: "p", fingerprint: "fpB", serviceName: "mads-2")
        #expect(DiscoveredInstance.dedupePreferringLive([a, b]).count == 2)
    }

    @Test func dedupeFallsBackToFirstWhenNoStableName() {
        let fp = String(repeating: "b", count: 64)
        let a = DiscoveredInstance(testId: fp, name: "mads", project: "p", fingerprint: fp, serviceName: "mads-111")
        let b = DiscoveredInstance(testId: fp, name: "mads", project: "p", fingerprint: fp, serviceName: "mads-222")
        let out = DiscoveredInstance.dedupePreferringLive([a, b])
        #expect(out.count == 1) // beide pid-benannt → einer bleibt (kein Absturz/Doppel)
    }

    /// Eine Karteileiche der VORIGEN mads-Version (kein `iid`, damaliger projekt-eigener
    /// Fingerprint) trägt eine andere `id` als der lebende Eintrag, zeigt aber auf denselben
    /// Host und Port. Ohne die Endpunkt-Stufe steht sie als zweiter Eintrag in der Liste, der am
    /// veralteten Pin scheitert.
    @Test func dedupesStaleEntryPointingAtSameEndpoint() {
        let stale = DiscoveredInstance(testId: String(repeating: "8", count: 64), name: "mads Remote (p)",
                                       project: "p", fingerprint: String(repeating: "8", count: 64),
                                       serviceName: "mads-888888888888", host: "10.0.0.24", port: 57675)
        let live = DiscoveredInstance(testId: "d5fa5422ae18", name: "mads Remote (p)", project: "p",
                                      fingerprint: String(repeating: "2", count: 64),
                                      serviceName: "mads-d5fa5422ae18", instanceId: "d5fa5422ae18",
                                      host: "10.0.0.24", port: 57675)
        for input in [[stale, live], [live, stale]] {
            let out = DiscoveredInstance.dedupePreferringLive(input)
            #expect(out.count == 1)
            #expect(out.first?.txtInstanceId == "d5fa5422ae18")
        }
    }

    /// Zwei parallel offene Projekte lauschen auf verschiedenen Ports — die Endpunkt-Stufe darf sie
    /// nicht zusammenwerfen, obwohl sie sich seit der Host-Umstellung den Fingerprint teilen.
    @Test func keepsDistinctPortsSeparate() {
        let fp = String(repeating: "2", count: 64)
        let a = DiscoveredInstance(testId: "aaaaaaaaaaaa", name: "A", project: "a", fingerprint: fp,
                                   serviceName: "mads-aaaaaaaaaaaa", instanceId: "aaaaaaaaaaaa",
                                   host: "10.0.0.24", port: 57675)
        let b = DiscoveredInstance(testId: "bbbbbbbbbbbb", name: "B", project: "b", fingerprint: fp,
                                   serviceName: "mads-bbbbbbbbbbbb", instanceId: "bbbbbbbbbbbb",
                                   host: "10.0.0.24", port: 57246)
        #expect(DiscoveredInstance.dedupePreferringLive([a, b]).count == 2)
    }

    @Test func stableNameMatchesEitherScheme() {
        let fp = String(repeating: "c", count: 64)
        let live = DiscoveredInstance(testId: fp, name: "m", project: "p", fingerprint: fp, serviceName: "mads-\(fp.prefix(12))")
        let old = DiscoveredInstance(testId: fp, name: "m", project: "p", fingerprint: fp, serviceName: "mads-4242")
        let iidNamed = DiscoveredInstance(testId: "abc123abc123", name: "m", project: "p", fingerprint: fp,
                                          serviceName: "mads-abc123abc123", instanceId: "abc123abc123")
        #expect(live.isStablyNamed)
        #expect(!old.isStablyNamed)
        #expect(iidNamed.isStablyNamed)
    }

    /// Zwei parallel offene Projekte desselben Macs teilen sich jetzt den Host-fp. Sie dürfen NICHT
    /// zu einem Eintrag verschmelzen (das war der Grund für die `iid`) — und der Keychain-Schlüssel
    /// muss für beide der gemeinsame Host-fp sein, damit eine Kopplung für beide gilt.
    @Test func projectsShareHostFingerprintButStaySeparateEntries() {
        let fp = String(repeating: "d", count: 64)
        let a = DiscoveredInstance(testId: "aaaaaaaaaaaa", name: "A", project: "a", fingerprint: fp,
                                   serviceName: "mads-aaaaaaaaaaaa", instanceId: "aaaaaaaaaaaa")
        let b = DiscoveredInstance(testId: "bbbbbbbbbbbb", name: "B", project: "b", fingerprint: fp,
                                   serviceName: "mads-bbbbbbbbbbbb", instanceId: "bbbbbbbbbbbb")
        #expect(DiscoveredInstance.dedupePreferringLive([a, b]).count == 2)
        #expect(a.credentialKey == b.credentialKey)
        #expect(a.credentialKey == fp)
    }
}
