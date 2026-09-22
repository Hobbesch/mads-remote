import Testing
@testable import mads_remote

/// Der Reducer (`InstanceStore.apply`) + Wire-Decoding — der Kern des Live-Mirrors.
@MainActor
struct ReducerTests {
    @Test func statusAndCostCreateAndPatchStream() {
        let store = InstanceStore()
        store.apply(.statusUpdate(agentId: "a", status: .running, currentStep: "build", label: "mein-stream", role: "sub"))
        store.apply(.costUpdate(agentId: "a", totalCostUsd: 1.5, numTurns: 3, inputTokens: 100, outputTokens: 50))
        #expect(store.order == ["a"])
        #expect(store.streams["a"]?.status == .running)
        #expect(store.streams["a"]?.currentStep == "build")
        #expect(store.streams["a"]?.costUsd == 1.5)
        #expect(store.streams["a"]?.numTurns == 3)
        #expect(store.streams["a"]?.inputTokens == 100)
        #expect(store.streams["a"]?.label == "mein-stream")   // Name statt UUID
        #expect(store.streams["a"]?.role == "sub")
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
        if case .tool(let card)? = tl.last?.kind {
            #expect(card.ok == true)
            #expect(card.running == false)
        } else {
            Issue.record("letztes Item ist keine tool-Karte")
        }
    }

    @Test func ringBufferCapsAt800() {
        let store = InstanceStore()
        for i in 0..<850 { store.apply(.agentEvent(agentId: "a", event: .assistantText("m\(i)"))) }
        #expect(store.streams["a"]?.timeline.count == 800)
    }

    @Test func agentTimelineRebuildsAndIsIdempotent() {
        let store = InstanceStore()
        // Client verbindet mitten im Lauf: nur eine erste Live-Zeile ist angekommen …
        store.apply(.agentEvent(agentId: "a", event: .assistantText("erste Zeile")))
        // … dann kommt der Snapshot mit dem VOLLEN Verlauf (inkl. bereits gelaufenem Bash).
        store.apply(.agentTimeline(agentId: "a", events: [
            .assistantText("erste Zeile"),
            .toolUse(toolUseId: "t1", name: "Bash"),
            .toolResult(toolUseId: "t1", ok: true, summary: nil),
            .assistantText("zweite Zeile"),
        ]))
        var tl = store.streams["a"]?.timeline ?? []
        #expect(tl.count == 3) // text + tool(ok) + text — KEIN Duplikat der ersten Zeile
        if case .tool(let card)? = tl.dropFirst().first?.kind {
            #expect(card.name == "Bash"); #expect(card.ok == true)
        } else { Issue.record("Bash-Karte fehlt/kein ok") }
        // Live-Event NACH dem Snapshot hängt strikt an.
        store.apply(.agentEvent(agentId: "a", event: .assistantText("dritte Zeile")))
        tl = store.streams["a"]?.timeline ?? []
        #expect(tl.count == 4)
        // Zweiter Snapshot (z. B. nach Reconnect) ERSETZT, ohne zu duplizieren.
        store.apply(.agentTimeline(agentId: "a", events: [.assistantText("nur noch das")]))
        #expect(store.streams["a"]?.timeline.count == 1)
    }

    // MARK: - Inhalt der Werkzeug-Karten (vorher trug die Timeline nur den Tool-NAMEN)

    /// Wire-Contract: `tool_use` trägt `input`, `tool_result` trägt `output`. Beides muss auf der
    /// Karte landen — sonst steht dort nur „Bash", ohne Befehl und ohne Ergebnis.
    @Test func toolCardCarriesCommandDescriptionAndOutput() {
        let use = #"""
        {"channel":"event","msg":{"type":"agent_event","agentId":"a","event":{"kind":"tool_use","toolUseId":"t1","name":"Bash","input":{"command":"npm test","description":"Tests ausführen"}}}}
        """#
        let result = #"""
        {"channel":"event","msg":{"type":"agent_event","agentId":"a","event":{"kind":"tool_result","toolUseId":"t1","ok":true,"output":"3 passed"}}}
        """#
        let store = InstanceStore()
        guard case .agentEvent(_, let useEvent)? = WireFrame.decode(use)?.msg,
              case .agentEvent(_, let resultEvent)? = WireFrame.decode(result)?.msg else {
            Issue.record("Tool-Frames nicht decodiert"); return
        }
        store.apply(.agentEvent(agentId: "a", event: useEvent))

        // Schon WÄHREND der Ausführung muss der Befehl sichtbar sein (nicht erst mit dem Ergebnis).
        guard case .tool(let running)? = store.streams["a"]?.timeline.last?.kind else {
            Issue.record("keine tool-Karte"); return
        }
        #expect(running.command == "npm test")
        #expect(running.description == "Tests ausführen")
        #expect(running.running == true)
        #expect(running.ok == nil)

        store.apply(.agentEvent(agentId: "a", event: resultEvent))
        guard case .tool(let done)? = store.streams["a"]?.timeline.last?.kind else {
            Issue.record("keine tool-Karte"); return
        }
        #expect(done.output == "3 passed")
        #expect(done.ok == true)
        #expect(store.streams["a"]?.timeline.count == 1) // dieselbe Karte, kein zweites Item
    }

    /// Ohne `output` bleibt die Kurzfassung (`summary`) — besser als eine leere OUT-Zeile.
    @Test func toolResultFallsBackToSummary() {
        let store = InstanceStore()
        store.apply(.agentEvent(agentId: "a", event: .toolUse(toolUseId: "t1", name: "Read")))
        store.apply(.agentEvent(agentId: "a", event: .toolResult(toolUseId: "t1", ok: true, summary: "42 Zeilen")))
        guard case .tool(let card)? = store.streams["a"]?.timeline.last?.kind else {
            Issue.record("keine tool-Karte"); return
        }
        #expect(card.output == "42 Zeilen")
    }

    /// Ergebnis ohne zugehörigen Aufruf (Ringpuffer übergelaufen) → eigene Karte, statt verloren.
    @Test func orphanToolResultBecomesOwnCard() {
        let store = InstanceStore()
        store.apply(.agentEvent(agentId: "a", event: .toolResult(toolUseId: "weg", ok: false, output: "Fehler")))
        guard case .tool(let card)? = store.streams["a"]?.timeline.last?.kind else {
            Issue.record("keine tool-Karte"); return
        }
        #expect(card.ok == false)
        #expect(card.output == "Fehler")
        #expect(card.running == false)
    }

    /// TodoWrite ist eine To-do-Liste, keine Werkzeug-Zeile mit rohem JSON (wie am Mac).
    @Test func todoWriteBecomesTodoCard() {
        let frame = #"""
        {"channel":"event","msg":{"type":"agent_event","agentId":"a","event":{"kind":"tool_use","toolUseId":"t1","name":"TodoWrite","input":{"todos":[{"content":"Bridge prüfen","status":"completed"},{"content":"UI bauen","status":"in_progress"}]}}}}
        """#
        guard case .agentEvent(_, let event)? = WireFrame.decode(frame)?.msg else {
            Issue.record("kein agentEvent"); return
        }
        let store = InstanceStore()
        store.apply(.agentEvent(agentId: "a", event: event))
        guard case .todos(let todos)? = store.streams["a"]?.timeline.last?.kind else {
            Issue.record("keine todos-Karte"); return
        }
        #expect(todos.count == 2)
        #expect(todos[0].status == "completed")
        #expect(todos[1].content == "UI bauen")
    }

    /// Werkzeug-Aufrufe eines Teil-Agenten tragen dessen Namen — sonst sehen sie aus wie Aufrufe
    /// des Streams selbst.
    @Test func subAgentToolCallIsAttributed() {
        let store = InstanceStore()
        let taskInput: [String: JSONValue] = ["description": .string("Doku durchsuchen")]
        store.apply(.agentEvent(agentId: "a", event: .toolUse(toolUseId: "task1", name: "Task", input: taskInput)))
        store.apply(.agentEvent(agentId: "a", event: .toolUse(
            toolUseId: "t2", name: "Grep", input: ["pattern": .string("bridge")], parentToolUseId: "task1")))

        guard case .tool(let card)? = store.streams["a"]?.timeline.last?.kind else {
            Issue.record("keine tool-Karte"); return
        }
        #expect(card.viaSubAgent == "Doku durchsuchen")
        #expect(card.command == "bridge")

        // Aufruf des Streams selbst bleibt unmarkiert.
        store.apply(.agentEvent(agentId: "a", event: .toolUse(toolUseId: "t3", name: "Read")))
        guard case .tool(let own)? = store.streams["a"]?.timeline.last?.kind else {
            Issue.record("keine tool-Karte"); return
        }
        #expect(own.viaSubAgent == nil)
    }

    /// Die Berechtigungsanfrage muss den Input mitbringen — man soll nie „Bash" freigeben, ohne den
    /// Befehl zu sehen. `summary`/`command` liefern denselben Text wie der Desktop-Dialog.
    @Test func permissionRequestCarriesInputAndReason() {
        let frame = #"""
        {"channel":"event","msg":{"type":"permission_request","agentId":"a","requestId":"r1","toolName":"Bash","kind":"tool","input":{"command":"git push origin main"},"decisionReason":"Aktion wird für andere sichtbar","commandKind":"outward","blockedPath":"/repo"}}
        """#
        guard case .permissionRequest(let req)? = WireFrame.decode(frame)?.msg else {
            Issue.record("kein permissionRequest"); return
        }
        #expect(req.command == "git push origin main")
        #expect(req.summary == "Shell-Befehl ausführen: git push origin main")
        #expect(req.decisionReason == "Aktion wird für andere sichtbar")
        #expect(req.commandKind == "outward")
        #expect(req.blockedPath == "/repo")
    }

    /// Eine Anfrage OHNE Input (alte mads-Version) darf nicht verworfen werden — sonst bliebe der
    /// Stream ohne Entscheidung hängen. Sie fällt auf den generischen Satz zurück.
    @Test func permissionRequestWithoutInputStillDecodes() {
        let frame = #"{"channel":"event","msg":{"type":"permission_request","agentId":"a","requestId":"r1","toolName":"Bash","kind":"tool"}}"#
        guard case .permissionRequest(let req)? = WireFrame.decode(frame)?.msg else {
            Issue.record("kein permissionRequest"); return
        }
        #expect(req.command == nil)
        #expect(req.summary == "Shell-Befehl ausführen")
    }

    @Test func decodesAgentTimelineFrame() {
        let frame = #"{"channel":"event","msg":{"type":"agent_timeline","agentId":"a","events":[{"kind":"assistant_text","text":"hi"},{"kind":"tool_use","toolUseId":"t1","name":"Bash","input":{}}]}}"#
        let wf = WireFrame.decode(frame)
        guard case .agentTimeline(let id, let events)? = wf?.msg else {
            Issue.record("kein agentTimeline decodiert"); return
        }
        #expect(id == "a")
        #expect(events.count == 2)
    }

    /// Wire-Contract zur mads-Seite: user_text trägt Text + Bild-Anhänge (kleines Inline-Thumbnail,
    /// KEIN Vollbild). Muss als .user-Timeline-Item mit Anhängen ankommen, damit das echte Bild
    /// statt eines Zählers erscheint. `path` ist Mac-only und wird hier bewusst ignoriert.
    @Test func decodesUserTextWithImageAttachment() {
        let frame = #"""
        {"v":1,"id":"x","ts":0,"channel":"event","msg":{"type":"agent_event","agentId":"a","event":{"kind":"user_text","text":"schau dir das an","attachments":[{"id":"att-1","mediaType":"image/png","thumbBase64":"AAAA","thumbMediaType":"image/jpeg","path":"/repo/.mads/attachments/att-1.png"}]}}}
        """#
        guard case .agentEvent(let agentId, let event)? = WireFrame.decode(frame)?.msg else {
            Issue.record("kein agentEvent decodiert"); return
        }
        #expect(agentId == "a")
        guard case .userText(let text, let atts) = event else {
            Issue.record("kein userText decodiert"); return
        }
        #expect(text == "schau dir das an")
        #expect(atts.count == 1)
        #expect(atts.first?.id == "att-1")
        #expect(atts.first?.mediaType == "image/png")
        #expect(atts.first?.thumbBase64 == "AAAA")

        // Reducer: landet als .user-Item MIT Anhang in der Timeline.
        let store = InstanceStore()
        store.apply(.agentEvent(agentId: "a", event: event))
        guard case .user(let t, let a)? = store.streams["a"]?.timeline.last?.kind else {
            Issue.record("kein .user-Item"); return
        }
        #expect(t == "schau dir das an")
        #expect(a.count == 1)
    }

    /// Ohne Anhänge bleibt es eine normale Text-Anweisung (leeres Array, kein Absturz).
    @Test func decodesUserTextWithoutAttachments() {
        let frame = #"{"v":1,"id":"x","ts":0,"channel":"event","msg":{"type":"agent_event","agentId":"a","event":{"kind":"user_text","text":"nur text"}}}"#
        guard case .agentEvent(_, let event)? = WireFrame.decode(frame)?.msg,
              case .userText(let text, let atts) = event else {
            Issue.record("kein userText decodiert"); return
        }
        #expect(text == "nur text")
        #expect(atts.isEmpty)
    }

    @Test func decodesEventFrameAndApplies() {
        let frame = #"{"v":1,"id":"x","ts":0,"channel":"event","msg":{"type":"status_update","agentId":"z","status":"waiting_input"}}"#
        let wf = WireFrame.decode(frame)
        #expect(wf?.channel == "event")
        guard case .statusUpdate(let id, let status, _, _, _)? = wf?.msg else {
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
