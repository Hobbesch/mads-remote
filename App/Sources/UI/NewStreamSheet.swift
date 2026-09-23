import SwiftUI

/// „Neuer Stream" vom Gerät aus — das Gegenstück zum New-Stream-Dialog am Mac.
///
/// Bewusst kürzer als dort: Name und Auftrag stehen oben, die Betriebsart darunter mit denselben
/// Vorbelegungen, die der Mac für einen neuen Stream nimmt. Den Branch leitet mads aus dem Namen ab
/// — die Zeile zeigt ihn nur an, statt ihn editierbar zu machen: auf dem Handy ist ein frei
/// getippter Branch-Name mehr Fehlerquelle als Nutzen, und der abgeleitete ist zeichengenau
/// derselbe, den der Mac vergeben würde.
struct NewStreamSheet: View {
    let session: InstanceSession
    /// Wird mit der neuen agentId aufgerufen, sobald der Start-Befehl draussen ist.
    let onStarted: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var prompt = ""
    @State private var model: String
    @State private var effort: EffortMode?
    @State private var permissionMode: PermissionMode = .auto   // wie am Mac
    @State private var sandboxMode: SandboxMode = .on
    @State private var accountId: String
    @State private var starting = false
    @StateObject private var dictation = DictationController()

    /// Vorbelegung aus dem Stream, aus dem heraus der neue eröffnet wird — „so wie der, an dem ich
    /// gerade arbeite" ist die brauchbarste Annahme, die das Gerät treffen kann.
    init(session: InstanceSession, from current: Stream?, onStarted: @escaping (String) -> Void) {
        self.session = session
        self.onStarted = onStarted
        _model = State(initialValue: current?.model ?? ModelCatalog.models.first?.id ?? "")
        _effort = State(initialValue: current?.effort)
        _accountId = State(initialValue: current?.accountId ?? session.store.accounts.activeId)
    }

    private var store: InstanceStore { session.store }

    private var canStart: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && session.phase == .live
            && !starting
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Auftrag") {
                    TextField("Name, z. B. „auth-fix\"", text: $label)
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("Was soll der Stream tun?", text: $prompt, axis: .vertical)
                            .lineLimit(3...10)
                        micButton
                    }
                    if let status = dictation.statusText {
                        HStack(spacing: 6) {
                            if dictation.showsSpinner { ProgressView().controlSize(.mini) }
                            Text(status)
                                .font(.caption2)
                                .foregroundStyle(dictation.isError ? Color.red : .secondary)
                        }
                    }
                }

                Section {
                    Picker("Modell", selection: $model) {
                        ForEach(ModelCatalog.models) { Text($0.label).tag($0.id) }
                    }
                    let levels = ModelCatalog.effortLevels(for: model)
                    if !levels.isEmpty {
                        Picker("Effort", selection: effortBinding(levels)) {
                            ForEach(levels, id: \.self) { Text($0.label).tag($0) }
                        }
                    }
                    Picker("Modus", selection: $permissionMode) {
                        ForEach(PermissionMode.selectable, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Sandbox", selection: $sandboxMode) {
                        ForEach(SandboxMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if !store.accounts.profiles.isEmpty {
                        Picker("Konto", selection: $accountId) {
                            ForEach(store.accounts.profiles) { profile in
                                Text(store.accounts.isOnCooldown(profile.id)
                                     ? "\(profile.label) (Kontingent erschöpft)" : profile.label)
                                    .tag(profile.id)
                            }
                        }
                    }
                } header: {
                    Text("Betriebsart")
                } footer: {
                    // Die beiden Folgen, die man vor dem Start kennen will — hier als Hinweis statt
                    // als Rückfrage: sie stehen sichtbar da, BEVOR „Starten" getippt wird.
                    VStack(alignment: .leading, spacing: 4) {
                        if permissionMode.runsUnattended {
                            Text("Der Agent führt Werkzeuge ohne Rückfrage aus — es kommen keine Freigabe-Karten.")
                                .foregroundStyle(.orange)
                        }
                        if sandboxMode == .off {
                            Text("Freigang: kein Egress-Schutz, Secret-Ablagen erreichbar.")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    LabeledContent("Branch", value: StreamCommand.branchName(for: label))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } footer: {
                    if let project = store.project {
                        Text("Eigener Worktree, abgezweigt von origin/\(project.defaultBranch).")
                    } else {
                        Text("Kein Projekt gemeldet — der Stream liefe ohne eigenen Worktree. Erst mit mads verbinden.")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Neuer Stream")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Abbrechen") { dictation.cancel(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Starten") { start() }
                        .disabled(!canStart)
                        .bold()
                }
            }
            .onDisappear { dictation.cancel() }
        }
        .presentationDetents([.large])
    }

    /// Effort ist optional (Haiku kennt keinen), der Picker braucht aber einen Wert — auf die
    /// höchste unterstützte Stufe fallen, statt eine leere Zeile zu zeigen.
    private func effortBinding(_ levels: [EffortMode]) -> Binding<EffortMode> {
        Binding(
            get: { effort.flatMap { levels.contains($0) ? $0 : nil } ?? levels.last ?? .high },
            set: { effort = $0 })
    }

    private var micButton: some View {
        Button {
            Task {
                if dictation.isRecording {
                    if let text = await dictation.stopAndTranscribe(), !text.isEmpty {
                        prompt = prompt.isEmpty ? text : prompt + " " + text
                    }
                } else {
                    await dictation.startRecording()
                }
            }
        } label: {
            Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic.fill")
                .font(.title3)
                .foregroundStyle(dictation.isRecording ? Color.red : (dictation.isBusy ? Color.secondary : Color.accentColor))
                .symbolEffect(.pulse, isActive: dictation.isRecording)
        }
        .buttonStyle(.plain)
        .disabled(dictation.isBusy)
        .accessibilityLabel(dictation.isRecording ? "Diktat stoppen" : "Auftrag diktieren")
    }

    private func start() {
        starting = true
        let levels = ModelCatalog.effortLevels(for: model)
        Task {
            let id = await session.startStream(
                label: label, prompt: prompt, model: model,
                // Kennt das Modell keinen Effort (Haiku), gar nichts schicken statt einer Stufe,
                // die der SDK dann verwirft.
                effort: levels.isEmpty ? nil : effortBinding(levels).wrappedValue,
                permissionMode: permissionMode, sandboxMode: sandboxMode, accountId: accountId)
            starting = false
            if let id {
                onStarted(id)
                dismiss()
            }
            // Sonst offen lassen: der Fehler steht im Store und der getippte Auftrag ist nicht weg.
        }
    }
}
