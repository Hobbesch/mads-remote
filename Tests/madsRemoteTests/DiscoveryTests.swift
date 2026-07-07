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
}
