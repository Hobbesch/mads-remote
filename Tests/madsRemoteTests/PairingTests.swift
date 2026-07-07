import Testing
@testable import mads_remote

/// Der QR-Pairing-Payload-Parser (`mads-remote://pair?…`) — pure, von der Kamera entkoppelt.
struct PairingTests {
    @Test func parsesValidPayload() {
        let p = PairingPayload.parse("mads-remote://pair?pv=1&fp=abc123&pin=456789")
        #expect(p?.fingerprint == "abc123")
        #expect(p?.pin == "456789")
        #expect(p?.protocolVersion == "1")
    }

    @Test func toleratesWhitespace() {
        let p = PairingPayload.parse("  mads-remote://pair?fp=ff&pin=000000\n")
        #expect(p?.pin == "000000")
        #expect(p?.fingerprint == "ff")
    }

    @Test func rejectsWrongScheme() {
        #expect(PairingPayload.parse("https://pair?fp=x&pin=1") == nil)
        #expect(PairingPayload.parse("mads-remote://other?fp=x&pin=1") == nil)
    }

    @Test func rejectsMissingFields() {
        #expect(PairingPayload.parse("mads-remote://pair?fp=x") == nil)   // kein pin
        #expect(PairingPayload.parse("mads-remote://pair?pin=1") == nil)  // kein fp
        #expect(PairingPayload.parse("garbage") == nil)
    }
}
