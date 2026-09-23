import SwiftUI

/// Die „Menüleiste" eines Streams — als Sheet statt als Dauer-Einblendung.
///
/// Platzentscheidung: am Gerät ist vertikaler Raum das knappste Gut, und Modell/Modus/Sandbox/Konto
/// ändert man selten, liest sie aber gern nach. Ein `Menu` in der Navigationsleiste kostet null
/// Höhe, kann aber keine Balken rendern — deshalb ein Sheet auf halber Höhe: null Platz im
/// Normalbetrieb, volle Darstellung beim Öffnen. Es ersetzt zugleich das alte `ellipsis`-Menü, es
/// gibt also EINEN Einstieg statt zweier.
///
/// Keine Umstellung wird optimistisch angezeigt: jede geht als Befehl raus, und erst mads'
/// `status_update` schreibt sie in den Store. Was hier steht, ist damit immer die Betriebsart, in
/// der der Stream WIRKLICH läuft.
struct StreamSettingsSheet: View {
    let session: InstanceSession
    let streamId: String

    @Environment(\.dismiss) private var dismiss

    /// Bestätigungen für die Umstellungen mit Tragweite (Freigang, unbeaufsichtigte Modi).
    @State private var pendingSandbox: SandboxMode?
    @State private var pendingMode: PermissionMode?
    @State private var confirmStop = false
    @State private var confirmIntegrate = false
    @State private var confirmCreatePR = false

    private var store: InstanceStore { session.store }
    private var stream: Stream? { store.streams[streamId] }

    var body: some View {
        NavigationStack {
            List {
                if let stream {
                    usageSection(stream)
                    modelSection(stream)
                    modeSection(stream)
                    if stream.role != "integrator" { sandboxSection(stream) }
                    accountSection(stream)
                    actionSection(stream)
                } else {
                    Text("Stream nicht mehr vorhanden").foregroundStyle(.secondary)
                }
            }
            .navigationTitle(stream?.label ?? streamId)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // ALERTS, nicht `confirmationDialog`: aus einem Sheet heraus rendert iOS den Abbrechen-Knopf
        // eines confirmationDialog NICHT — die Rückfrage vor „Sandbox aus" stand dann ohne sichtbaren
        // Ausweg da (am Gerät verifiziert). Ein Alert zeigt beide Knöpfe verlässlich.
        .alert("Sandbox ausschalten (Freigang)?", isPresented: showing($pendingSandbox), presenting: pendingSandbox) { mode in
            Button("Sandbox ausschalten", role: .destructive) {
                Task { await session.setSandboxMode(agentId: streamId, mode: mode) }
                pendingSandbox = nil
            }
            Button("Abbrechen", role: .cancel) { pendingSandbox = nil }
        } message: { _ in
            Text("""
                Der Agent verliert alle Sandbox-Schutzschichten: Egress unbeschränkt, Secret-Ablagen \
                (~/.ssh, ~/.aws) erreichbar, Schreiben ausserhalb des Worktrees möglich.

                Geländer: Freigang wird nie gespeichert, der Autopilot pusht und erstellt darin keine \
                PRs, und nach 15 Min. Inaktivität fällt der Stream von selbst zurück.
                """)
        }
        .alert("Unbeaufsichtigt ausführen?", isPresented: showing($pendingMode), presenting: pendingMode) { mode in
            Button(mode.shortLabel, role: .destructive) {
                Task { await session.setPermissionMode(agentId: streamId, mode: mode) }
                pendingMode = nil
            }
            Button("Abbrechen", role: .cancel) { pendingMode = nil }
        } message: { _ in
            Text("""
                In diesem Modus führt der Agent Werkzeuge ohne Rückfrage aus — auch während niemand \
                am Mac sitzt. Du bekommst dann keine Freigabe-Karten mehr auf dieses Gerät.
                """)
        }
        .alert("Pull Request erstellen?", isPresented: $confirmCreatePR) {
            Button("PR erstellen") { act("create_pr") }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("Erstellt einen außen sichtbaren Pull Request aus diesem Stream.") }
        .alert("Integrieren (nach main mergen)?", isPresented: $confirmIntegrate) {
            Button("Integrieren", role: .destructive) { act("integrate_pr") }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("Merged diesen Stream nach main. Irreversibel.") }
        .alert("Stream stoppen?", isPresented: $confirmStop) {
            Button("Stoppen", role: .destructive) {
                Task { await session.stopAgent(agentId: streamId) }
                dismiss()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("Beendet den Agenten und schliesst den Stream. Der Worktree bleibt bestehen.") }
    }

    /// `Binding<Bool>` aus einem optionalen Zustand: gesetzt = Dialog offen, Schliessen = zurück auf nil.
    private func showing<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    // MARK: - Abschnitte

    /// Plan-Nutzungslimits des Kontos, unter dem DIESER Stream läuft.
    @ViewBuilder private func usageSection(_ stream: Stream) -> some View {
        let accountId = stream.accountId ?? store.accounts.activeId
        if let usage = store.usage[accountId], usage.hasAnyWindow {
            Section("Kontingent · \(store.accounts.label(accountId))") {
                UsageBars(usage: usage)
            }
        } else {
            Section("Kontingent") {
                Text("Noch nichts gemessen — mads liest die Plan-Limits am Ende eines Turns.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func modelSection(_ stream: Stream) -> some View {
        Section("Modell") {
            Picker("Modell", selection: bind(stream.model ?? "") { id in
                Task { await session.setModelEffort(agentId: streamId, model: id) }
            }) {
                ForEach(modelOptions(stream), id: \.id) { option in
                    Text(option.label).tag(option.id)
                }
            }
            let levels = ModelCatalog.effortLevels(for: stream.model)
            if !levels.isEmpty {
                Picker("Effort", selection: bind(stream.effort ?? .high) { level in
                    Task { await session.setModelEffort(agentId: streamId, effort: level) }
                }) {
                    ForEach(levels, id: \.self) { Text($0.label).tag($0) }
                }
            }
            // Läuft real etwas anderes als angefordert, sagt mads das — hier sichtbar machen,
            // sonst verbrennt ein teureres Modell unbemerkt Kontingent.
            if stream.modelMismatch, let active = stream.activeModel {
                Label("Läuft real auf \(ModelCatalog.label(for: active))", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Der Katalog — plus, falls der Stream auf einem Modell läuft, das der Katalog nicht kennt,
    /// dieses als zusätzliche Zeile. Ohne den Zusatz fände der Picker keinen passenden Eintrag und
    /// zeigte einen LEEREN Wert an, obwohl der Stream sehr wohl auf etwas läuft.
    private func modelOptions(_ stream: Stream) -> [ModelOption] {
        let models = ModelCatalog.models
        guard let current = stream.model, !current.isEmpty,
              !models.contains(where: { $0.id == current }) else { return models }
        return models + [ModelOption(id: current, label: current, effort: [])]
    }

    private func modeSection(_ stream: Stream) -> some View {
        Section {
            Picker("Modus", selection: bind(stream.permissionMode ?? .default) { mode in
                // Unbeaufsichtigte Modi erst nach Rückfrage — aus der Ferne ist das die Umstellung
                // mit der grössten Tragweite. Wird sie abgebrochen, schnappt der Picker von selbst
                // zurück: sein Wert kommt aus dem Store, den nur mads' Bestätigung ändert.
                if mode.runsUnattended {
                    pendingMode = mode
                } else {
                    Task { await session.setPermissionMode(agentId: streamId, mode: mode) }
                }
            }) {
                ForEach(PermissionMode.selectable, id: \.self) { Text($0.label).tag($0) }
            }
        } footer: {
            if stream.permissionMode?.runsUnattended == true {
                Text("Der Agent führt Werkzeuge ohne Rückfrage aus — es kommen keine Freigabe-Karten mehr.")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func sandboxSection(_ stream: Stream) -> some View {
        Section {
            Picker("Sandbox", selection: bind(stream.sandboxMode ?? .on) { mode in
                // Zurück zu „an" geht ohne Rückfrage — verschärfen darf nie im Weg stehen.
                if mode == .off {
                    pendingSandbox = mode
                } else {
                    Task { await session.setSandboxMode(agentId: streamId, mode: mode) }
                }
            }) {
                ForEach(SandboxMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        } footer: {
            switch stream.sandboxMode ?? .on {
            case .on:
                Text("Schreiben nur im Worktree, Egress nur zu Paketquellen.")
            case .targets:
                Text("Sandbox bleibt aktiv; zusätzlich sind die in mads hinterlegten Untersuchungsziele per HTTPS erreichbar.")
            case .off:
                Text("Freigang: kein Egress-Schutz, Secret-Ablagen erreichbar. Fällt nach 15 Min. Inaktivität automatisch zurück.")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func accountSection(_ stream: Stream) -> some View {
        Section {
            Picker("Konto", selection: bind(stream.accountId ?? store.accounts.activeId) { id in
                Task { await session.setAccount(id, agentId: streamId) }
            }) {
                ForEach(store.accounts.profiles) { profile in
                    Text(store.accounts.isOnCooldown(profile.id)
                         ? "\(profile.label) (Kontingent erschöpft)" : profile.label)
                        .tag(profile.id)
                }
            }
        } footer: {
            Text("Ein Kontowechsel startet den Agenten im Zielkonto neu und setzt dieselbe Sitzung fort — der Verlauf bleibt, der Stream pausiert kurz.")
        }
    }

    private func actionSection(_ stream: Stream) -> some View {
        Section("Aktionen") {
            Button { Task { await session.interrupt(agentId: streamId) } } label: {
                Label("Unterbrechen", systemImage: "stop.circle")
            }
            Button { act("sync_branch") } label: {
                Label("Sync (rebase)", systemImage: "arrow.triangle.2.circlepath")
            }
            Button { act("gate_task") } label: {
                Label("Gate ausführen", systemImage: "checkmark.seal")
            }
            Button { confirmCreatePR = true } label: {
                Label("PR erstellen", systemImage: "arrow.triangle.pull")
            }
            // `.tint(.red)` zusätzlich zur Rolle: die Rolle färbt nur den TEXT rot, das Symbol
            // behielt den Akzent-Tint — eine halb rote Zeile las sich wie ein Darstellungsfehler.
            Button(role: .destructive) { confirmIntegrate = true } label: {
                Label("Integrieren", systemImage: "arrow.triangle.merge")
            }
            .tint(.red)
            Button(role: .destructive) { confirmStop = true } label: {
                Label("Stream stoppen", systemImage: "xmark.circle")
            }
            .tint(.red)
        }
    }

    // MARK: - Bausteine

    /// Ein Picker-Binding, das NICHT selbst speichert: `get` liest den Store (die Wahrheit, die nur
    /// mads' `status_update` ändert), `set` schickt den Befehl raus.
    ///
    /// Genau daher schnappt der Picker nach einer abgebrochenen Rückfrage von allein zurück — es
    /// gibt keinen lokalen Zwischenstand, der die falsche Betriebsart behaupten könnte.
    private func bind<T: Hashable>(_ current: T, onChange: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: { current }, set: { new in if new != current { onChange(new) } })
    }

    private func act(_ type: String) {
        Task { await session.streamAction(type, agentId: streamId) }
    }
}

/// Die drei Kontingent-Fenster als Balken (wie `UsageMeter` am Mac). Anders als dort werden hier
/// ALLE gemeldeten Fenster gezeigt — im Sheet ist Platz, und die Frage „wie viel habe ich noch"
/// ist genau der Grund, warum man das Menü aus der Ferne öffnet.
struct UsageBars: View {
    let usage: AccountUsage

    private static let warnAt = 75.0
    private static let critAt = 95.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let w = usage.fiveHour { bar("5 Std.", w) }
            if let w = usage.sevenDay { bar("Woche", w) }
            if let w = usage.sevenDayOpus { bar("Woche · Opus/Fable", w) }
            if let subscription = usage.subscription {
                Text("Abo: \(subscription)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func bar(_ label: String, _ win: UsageWindow) -> some View {
        let pct = max(0, min(100, win.utilization ?? 0))
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label).font(.caption)
                Spacer(minLength: 4)
                Text("\(Int(pct.rounded())) %").font(.caption).bold().foregroundStyle(tone(pct))
                if let reset = Self.resetLabel(win.resetsAt) {
                    Text(reset).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(tone(pct)).frame(width: geo.size.width * pct / 100)
                }
            }
            .frame(height: 5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(Int(pct.rounded())) Prozent verbraucht")
    }

    private func tone(_ pct: Double) -> Color {
        pct >= Self.critAt ? .red : pct >= Self.warnAt ? .orange : .green
    }

    /// „in 12 Min." / „14:30" / „Do, 14:30" — dieselbe Staffelung wie am Mac.
    static func resetLabel(_ resetsAt: Double?, now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let date = Date(timeIntervalSince1970: resetsAt / 1000)
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded())
        if minutes <= 0 { return "jetzt" }
        if minutes < 60 { return "in \(minutes) Min." }

        var time = Date.FormatStyle(date: .omitted, time: .shortened)
        time.locale = Locale(identifier: "de_CH")
        if minutes < 24 * 60 { return date.formatted(time) }

        var weekday = Date.FormatStyle(date: .omitted, time: .omitted)
        weekday.locale = Locale(identifier: "de_CH")
        return "\(date.formatted(weekday.weekday(.abbreviated))), \(date.formatted(time))"
    }
}

extension AccountUsage {
    /// Gibt es überhaupt ein Fenster zum Anzeigen? Ohne diese Prüfung stünde eine leere Karte da.
    var hasAnyWindow: Bool { fiveHour != nil || sevenDay != nil || sevenDayOpus != nil }
}
