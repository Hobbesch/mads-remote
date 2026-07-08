import Testing
@testable import mads_remote

/// TXT→Felder-Abbildung der Bonjour-Discovery (pure, ohne NWBrowser).
struct DiscoveryTests {
    @Test func parsesFullTxtRecord() {
        let txt = ["name": "Hobbesch/mads", "project": "mads", "pid": "4242", "pv": "1", "fp": "abcd1234"]
        let f = DiscoveredInstance.fields(txt: txt, serviceName: "mads-4242")
        #expect(f.name == "Hobbesch/mads")
        #expect(f.project == "mads")
        #expect(f.pid == "4242")
        #expect(f.pv == "1")
        #expect(f.fp == "abcd1234")
    }

    @Test func fallsBackToServiceNameWhenTxtMissing() {
        let f = DiscoveredInstance.fields(txt: [:], serviceName: "mads-999")
        #expect(f.name == "mads-999")
        #expect(f.project == "")
        #expect(f.pid == nil)
        #expect(f.fp == nil)
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

    @Test func isFingerprintNamedMatchesScheme() {
        let fp = String(repeating: "c", count: 64)
        let live = DiscoveredInstance(testId: fp, name: "m", project: "p", fingerprint: fp, serviceName: "mads-\(fp.prefix(12))")
        let old = DiscoveredInstance(testId: fp, name: "m", project: "p", fingerprint: fp, serviceName: "mads-4242")
        #expect(live.isFingerprintNamed)
        #expect(!old.isFingerprintNamed)
    }
}
