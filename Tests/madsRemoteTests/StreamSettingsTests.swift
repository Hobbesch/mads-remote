import Foundation
import Testing
@testable import mads_remote

/// Die Menüleiste eines Streams: Betriebsart spiegeln (status_update/model_active), Kontingent
/// anzeigen (accounts_update/account_usage) und die Umstell-Befehle korrekt bauen.
///
/// Warum das Tests braucht: alle drei Fehlerarten sind STILL. Ein nicht dekodiertes Feld zeigt
/// „—" statt des Werts, ein falscher `rawValue` wird von der Bridge verworfen (am Gerät passiert
/// einfach nichts), und ein `nil`-Feld im Befehl ändert das falsche Ding.
@MainActor
struct StreamSettingsTests {
    // MARK: - Spiegeln

    @Test func statusUpdateCarriesTheWholeOperatingMode() {
        let store = InstanceStore()
        store.apply(.statusUpdate(StatusUpdate(
            agentId: "a", status: .running, label: "auth-fix", role: "sub",
            accountId: "work", sandboxMode: .targets,
            model: "claude-sonnet-5", effort: .xhigh, permissionMode: .auto)))

        let stream = store.streams["a"]
        #expect(stream?.accountId == "work")
        #expect(stream?.sandboxMode == .targets)
        #expect(stream?.model == "claude-sonnet-5")
        #expect(stream?.effort == .xhigh)
        #expect(stream?.permissionMode == .auto)
    }

    /// Ein späteres `status_update` OHNE die Konfig-Felder (ältere mads-Version, oder ein Pfad, der
    /// nur Status meldet) darf den bekannten Stand nicht löschen — sonst flackerte das Menü bei
    /// jedem Statuswechsel auf „—".
    @Test func partialStatusUpdateKeepsKnownConfiguration() {
        let store = InstanceStore()
        store.apply(.statusUpdate(StatusUpdate(
            agentId: "a", status: .running, model: "claude-opus-5", permissionMode: .plan)))
        store.apply(.statusUpdate(StatusUpdate(agentId: "a", status: .paused)))

        #expect(store.streams["a"]?.status == .paused)
        #expect(store.streams["a"]?.model == "claude-opus-5")
        #expect(store.streams["a"]?.permissionMode == .plan)
    }

    @Test func decodesStatusUpdateWithConfigurationFromWire() {
        let frame = #"""
        {"channel":"event","msg":{"type":"status_update","agentId":"z","status":"running",
        "accountId":"privat","sandboxMode":"off","model":"claude-fable-5-1","effort":"ultracode",
        "permissionMode":"bypassPermissions"}}
        """#
        guard case .statusUpdate(let u)? = WireFrame.decode(frame)?.msg else {
            Issue.record("kein statusUpdate decodiert"); return
        }
        #expect(u.accountId == "privat")
        #expect(u.sandboxMode == .off)
        #expect(u.model == "claude-fable-5-1")
        #expect(u.effort == .ultracode)
        #expect(u.permissionMode == .bypassPermissions)
    }

    /// Forward-Kompatibilität: ein mads mit einem künftigen Sandbox-/Permission-Modus darf die
    /// Nachricht nicht sprengen. Das unbekannte Feld bleibt leer, der Rest kommt an — sonst stünde
    /// der Stream still, weil sein status_update verworfen wurde.
    @Test func unknownEnumValueDoesNotDropTheMessage() {
        let frame = #"""
        {"channel":"event","msg":{"type":"status_update","agentId":"z","status":"running",
        "sandboxMode":"quantum","permissionMode":"telepathy","model":"claude-opus-5"}}
        """#
        guard case .statusUpdate(let u)? = WireFrame.decode(frame)?.msg else {
            Issue.record("statusUpdate wurde verworfen statt teilweise dekodiert"); return
        }
        #expect(u.sandboxMode == nil)
        #expect(u.permissionMode == nil)
        #expect(u.model == "claude-opus-5")   // der bekannte Teil kommt trotzdem an
    }

    @Test func modelActiveMarksTheMismatch() {
        let store = InstanceStore()
        store.apply(.statusUpdate(StatusUpdate(agentId: "a", model: "claude-opus-5")))
        store.apply(.modelActive(agentId: "a", active: "claude-fable-5-1", mismatch: true))

        #expect(store.streams["a"]?.activeModel == "claude-fable-5-1")
        #expect(store.streams["a"]?.modelMismatch == true)
    }

    // MARK: - Konten & Kontingent

    @Test func decodesAccountsAndUsage() {
        let accountsFrame = #"""
        {"channel":"event","msg":{"type":"accounts_update","accounts":{
        "profiles":[{"id":"work","label":"Arbeit","configDir":"/Users/x/.claude","email":"a@b.ch"},
        {"id":"privat","label":"Privat","configDir":"/Users/x/.claude-privat"}],
        "activeId":"work","cooldowns":{"privat":{"until":9999999999999,"window":"five_hour","rejected":true}}}}}
        """#
        guard case .accountsUpdate(let accounts)? = WireFrame.decode(accountsFrame)?.msg else {
            Issue.record("kein accountsUpdate decodiert"); return
        }
        #expect(accounts.profiles.count == 2)
        #expect(accounts.activeId == "work")
        #expect(accounts.label("work") == "Arbeit")
        #expect(accounts.label("unbekannt") == "unbekannt")   // Drift → ID statt „?"
        #expect(accounts.isOnCooldown("privat"))
        #expect(!accounts.isOnCooldown("work"))

        let usageFrame = #"""
        {"channel":"event","msg":{"type":"account_usage","accountId":"work",
        "fiveHour":{"utilization":42,"resetsAt":1000},"sevenDay":{"utilization":18},
        "sevenDayOpus":{"utilization":97},"subscription":"max"}}
        """#
        guard case .accountUsage(let id, let usage)? = WireFrame.decode(usageFrame)?.msg else {
            Issue.record("kein accountUsage decodiert"); return
        }
        #expect(id == "work")
        #expect(usage.fiveHour?.utilization == 42)
        #expect(usage.sevenDayOpus?.utilization == 97)
        #expect(usage.subscription == "max")
        #expect(usage.peakUtilization == 97)   // treibt den roten Punkt am Menü-Icon
    }

    /// Ein `account_usage` ohne accountId darf keinen Geister-Eintrag anlegen — der würde sonst
    /// unter dem leeren Schlüssel landen und nie wieder jemandem zugeordnet.
    @Test func usageWithoutAccountIsIgnored() {
        let store = InstanceStore()
        store.apply(.accountUsage(accountId: "", usage: AccountUsage(fiveHour: UsageWindow(utilization: 50))))
        #expect(store.usage.isEmpty)
    }

    @Test func usageWithoutAnyWindowIsNotWorthShowing() {
        #expect(!AccountUsage().hasAnyWindow)
        #expect(AccountUsage(sevenDay: UsageWindow(utilization: 3)).hasAnyWindow)
        #expect(AccountUsage().peakUtilization == 0)
    }

    // MARK: - Befehle

    @Test func modelEffortOmitsUnsetFields() throws {
        let onlyModel = StreamCommand.modelEffort(agentId: "a", model: "claude-opus-5", effort: nil)
        #expect(onlyModel["model"] as? String == "claude-opus-5")
        #expect(onlyModel["effort"] == nil)

        let onlyEffort = StreamCommand.modelEffort(agentId: "a", model: nil, effort: .ultracode)
        #expect(onlyEffort["model"] == nil)
        #expect(onlyEffort["effort"] as? String == "ultracode")

        // Leerer String zählt wie „nicht gesetzt" — er käme sonst als Modell-ID "" im Sidecar an.
        #expect(StreamCommand.modelEffort(agentId: "a", model: "", effort: nil)["model"] == nil)
    }

    @Test func modeCommandsCarryTheProtocolRawValues() {
        // Die rawValues MÜSSEN exakt shared/protocol.ts entsprechen — die Bridge prüft sie gegen
        // ihre Allow-Liste und verwirft alles andere kommentarlos.
        #expect(StreamCommand.permissionMode(agentId: "a", mode: .bypassPermissions)["mode"] as? String == "bypassPermissions")
        #expect(StreamCommand.permissionMode(agentId: "a", mode: .acceptEdits)["mode"] as? String == "acceptEdits")
        #expect(StreamCommand.permissionMode(agentId: "a", mode: .default)["mode"] as? String == "default")
        #expect(StreamCommand.sandboxMode(agentId: "a", mode: .targets)["mode"] as? String == "targets")
        #expect(StreamCommand.sandboxMode(agentId: "a", mode: .off)["mode"] as? String == "off")
    }

    @Test func accountCommandOnlyCarriesAgentWhenGiven() {
        let forStream = StreamCommand.account("work", agentId: "a")
        #expect(forStream["agentId"] as? String == "a")

        // Ohne Stream ist es die Default-Wahl für NEUE Streams — ein leeres agentId-Feld würde
        // mads dagegen versuchen lassen, das Konto eines Streams namens "" zu wechseln.
        #expect(StreamCommand.account("work", agentId: nil)["agentId"] == nil)
        #expect(StreamCommand.account("work", agentId: "")["agentId"] == nil)
    }

    /// Welche Modi gelten als unbeaufsichtigt? Daran hängt die Rückfrage vor dem Umstellen —
    /// vergisst man einen, schaltet ein Tap den Agenten ohne Warnung frei.
    @Test func unattendedModesAreFlagged() {
        #expect(PermissionMode.auto.runsUnattended)
        #expect(PermissionMode.acceptEdits.runsUnattended)
        #expect(PermissionMode.bypassPermissions.runsUnattended)
        #expect(PermissionMode.dontAsk.runsUnattended)
        #expect(!PermissionMode.default.runsUnattended)
        #expect(!PermissionMode.plan.runsUnattended)
    }

    // MARK: - Randleiste

    @Test func railInitialsStayReadable() {
        #expect(StreamRail.initials("auth fix") == "AF")
        #expect(StreamRail.initials("mads/auth-fix") == "AF")   // Branch-Präfix trägt nichts bei
        #expect(StreamRail.initials("docs") == "DO")
        #expect(StreamRail.initials("") == "?")                 // nie leer, sonst unsichtbarer Knopf
    }

    @Test func modelCatalogFallsBackToTheRawId() {
        #expect(ModelCatalog.label(for: "claude-opus-5") == "Opus 5")
        // Drift: ein Modell, das mads kennt und der Katalog nicht → ID zeigen, nie falsch benennen.
        #expect(ModelCatalog.label(for: "claude-neu-9") == "claude-neu-9")
        #expect(ModelCatalog.label(for: nil) == "—")
        #expect(ModelCatalog.effortLevels(for: "claude-haiku-4-5").isEmpty)   // kein Effort-Regler
        #expect(ModelCatalog.effortLevels(for: "claude-sonnet-4-6") == [.low, .medium, .high])
    }

    @Test func usageResetLabelScalesWithDistance() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func label(minutesFromNow: Double) -> String? {
            UsageBars.resetLabel((now.timeIntervalSince1970 + minutesFromNow * 60) * 1000, now: now)
        }
        #expect(label(minutesFromNow: -5) == "jetzt")
        #expect(label(minutesFromNow: 12) == "in 12 Min.")
        #expect(label(minutesFromNow: 300)?.contains(":") == true)      // Uhrzeit
        #expect(label(minutesFromNow: 3000)?.contains(",") == true)     // Wochentag + Uhrzeit
        #expect(UsageBars.resetLabel(nil) == nil)
    }
}
