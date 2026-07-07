import Testing
@testable import mads_remote

/// Der Reducer (`InstanceStore.apply`) + Wire-Decoding — der Kern des Live-Mirrors.
@MainActor
struct ReducerTests {
    @Test func statusAndCostCreateAndPatchStream() {
        let store = InstanceStore()
        store.apply(.statusUpdate(agentId: "a", status: .running, currentStep: "build"))
        store.apply(.costUpdate(agentId: "a", totalCostUsd: 1.5, numTurns: 3, inputTokens: 100, outputTokens: 50))
        #expect(store.order == ["a"])
        #expect(store.streams["a"]?.status == .running)
        #expect(store.streams["a"]?.currentStep == "build")
        #expect(store.streams["a"]?.costUsd == 1.5)
        #expect(store.streams["a"]?.numTurns == 3)
        #expect(store.streams["a"]?.inputTokens == 100)
    }

    @Test func gitAndPrUpdate() {
        let store = InstanceStore()
        store.apply(.gitStatus(agentId: "a", behind: 2, ahead: 1, dirty: true, syncBlocked: nil))
        #expect(store.streams["a"]?.behind == 2)
        #expect(store.streams["a"]?.dirty == true)
    }

    @Test func timelineAppendsAndToolResultUpdatesInPlace() {
        let store = InstanceStore()
        store.apply(.agentEvent(agentId: "a", event: .assistantText("hi")))
        store.apply(.agentEvent(agentId: "a", event: .toolUse(toolUseId: "t1", name: "Bash")))
        store.apply(.agentEvent(agentId: "a", event: .toolResult(toolUseId: "t1", ok: true, summary: nil)))
        let tl = store.streams["a"]?.timeline ?? []
        #expect(tl.count == 2) // assistant + tool; result UPDATED die tool-Karte, kein neues Item
        if case .tool(_, _, let ok)? = tl.last?.kind {
            #expect(ok == true)
        } else {
            Issue.record("letztes Item ist keine tool-Karte")
        }
    }

    @Test func ringBufferCapsAt800() {
        let store = InstanceStore()
        for i in 0..<850 { store.apply(.agentEvent(agentId: "a", event: .assistantText("m\(i)"))) }
        #expect(store.streams["a"]?.timeline.count == 800)
    }

    @Test func decodesEventFrameAndApplies() {
        let frame = #"{"v":1,"id":"x","ts":0,"channel":"event","msg":{"type":"status_update","agentId":"z","status":"waiting_input"}}"#
        let wf = WireFrame.decode(frame)
        #expect(wf?.channel == "event")
        guard case .statusUpdate(let id, let status, _)? = wf?.msg else {
            Issue.record("kein statusUpdate decodiert"); return
        }
        #expect(id == "z")
        #expect(status == .waitingInput)
    }

    @Test func unknownTypeDoesNotCrash() {
        let frame = #"{"channel":"event","msg":{"type":"future_message_v99","agentId":"a"}}"#
        let wf = WireFrame.decode(frame)
        guard case .unknown(let type)? = wf?.msg else { Issue.record("nicht .unknown"); return }
        #expect(type == "future_message_v99")
    }

    @Test func decodesPairReply() {
        let wf = WireFrame.decode(#"{"channel":"pair-reply","ok":true,"token":"dev.secret","deviceId":"dev"}"#)
        #expect(wf?.channel == "pair-reply")
        #expect(wf?.ok == true)
        #expect(wf?.token == "dev.secret")
    }
}
