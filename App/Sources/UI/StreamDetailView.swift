import SwiftUI

/// Chat-/Timeline-Ansicht eines Streams mit Composer (send_input), Stream-Randleiste und
/// Einstellungs-Sheet. Beobachtet den `InstanceStore` und schlägt den Stream per id nach.
///
/// `streamId` ist `@State`, nicht `let`: die Randleiste schaltet IN DIESER ANSICHT um, statt eine
/// weitere Seite auf den Navigations-Stapel zu legen. Sonst stapelten sich bei fünf Wechseln fünf
/// Detail-Ansichten übereinander, jede mit eigener Verbindung ans Store-Objekt und eigenem „Zurück".
struct StreamDetailView: View {
    let session: InstanceSession
    @State private var streamId: String

    /// Entwürfe PRO Stream: beim Umschalten soll ein halb getippter Prompt nicht im falschen Stream
    /// landen — und beim Zurückschalten auch nicht weg sein.
    @State private var drafts: [String: String] = [:]
    @State private var showSettings = false
    @StateObject private var dictation = DictationController()

    init(session: InstanceSession, streamId: String) {
        self.session = session
        _streamId = State(initialValue: streamId)
    }

    private var store: InstanceStore { session.store }
    private var stream: Stream? { store.streams[streamId] }

    private var draft: Binding<String> {
        Binding(get: { drafts[streamId] ?? "" }, set: { drafts[streamId] = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    // Berechtigungsanfragen DIESES Streams direkt hier zeigen (mads-eigene Tool-Freigaben) —
                    // rendert nichts, wenn keine offen sind. (macOS-Systemdialoge sind OS-lokal, nicht spiegelbar.)
                    PermissionBanner(session: session, agentId: streamId)
                    timeline
                }
                // Nur bei mehr als einem Stream: bei einem einzigen wäre die Leiste 44 pt ohne Nutzen.
                if store.order.count > 1 {
                    Divider()
                    StreamRail(session: session, selected: $streamId)
                }
            }
            composer
        }
        .navigationTitle(streamTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { dictation.cancel() } // Ansicht verlassen → laufende Diktat-Aufnahme verwerfen
        // Stream gewechselt → ein laufendes Diktat gehört nicht in den neuen Stream.
        .onChange(of: streamId) { _, _ in dictation.cancel() }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { settingsButton } }
        .sheet(isPresented: $showSettings) {
            StreamSettingsSheet(session: session, streamId: streamId)
        }
    }

    /// Der Einstieg in die Menüleiste. Kostet keine Bildschirmhöhe und trägt zugleich die Warnung:
    /// ein farbiger Punkt, sobald ein Kontingent-Fenster in den Warnbereich läuft — genau die
    /// Information, für die man sonst erst das Menü öffnen müsste.
    private var settingsButton: some View {
        Button { showSettings = true } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal")
                if let tone = usageWarningTone {
                    Circle().fill(tone).frame(width: 7, height: 7).offset(x: 5, y: -3)
                }
            }
        }
        .accessibilityLabel("Stream-Einstellungen")
    }

    /// Farbe des Warnpunkts am Menü-Icon: ab 75 % orange, ab 95 % rot, darunter keiner.
    private var usageWarningTone: Color? {
        let accountId = stream?.accountId ?? store.accounts.activeId
        guard let peak = store.usage[accountId]?.peakUtilization else { return nil }
        if peak >= 95 { return .red }
        if peak >= 75 { return .orange }
        return nil
    }

    private let bottomID = "timeline-bottom"

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let stream {
                    VStack(alignment: .leading, spacing: 10) {
                        header(stream)
                        ForEach(stream.timeline) { item in
                            TimelineItemView(item: item)
                        }
                        // Läuft gerade etwas? Dann unten zeigen WORAN — wie die Arbeitszeile am Ende
                        // der mads-Timeline. Ohne sie wirkt ein arbeitender Stream auf dem Handy tot.
                        if isStreamActive {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.mini)
                                Text(stepLabel(stream))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Color.clear.frame(height: 1).id(bottomID) // Scroll-Anker am Ende
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                } else {
                    Text("Stream nicht mehr vorhanden").foregroundStyle(.secondary).padding()
                }
            }
            // Neue Nachricht (Timeline wächst) → ans Ende scrollen, damit der Live-Aufbau sichtbar
            // ist, ohne dass man raus/rein navigieren muss.
            .onChange(of: stream?.timeline.count ?? 0) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) }
        }
    }

    private var streamTitle: String { stream?.label ?? streamId }

    /// Verbindungszustand ÜBER dem Composer.
    ///
    /// Diese Ansicht liegt als aufgeschobene Seite über `InstanceDetailView`. Stirbt die Verbindung,
    /// wechselt die darunter auf „Nicht verbunden" — hier oben sah man davon nichts: alte Timeline,
    /// aktiver Pfeil, und jedes Senden verpuffte stumm. Deshalb hier ein eigener Riegel.
    @ViewBuilder private var connectionBanner: some View {
        if session.phase != .live {
            HStack(spacing: 8) {
                if isConnecting {
                    ProgressView().controlSize(.mini)
                    Text("Verbinde …")
                } else {
                    Image(systemName: "bolt.horizontal.circle.fill")
                    Text(disconnectReason).lineLimit(2)
                }
                Spacer(minLength: 0)
                if !isConnecting {
                    Button("Neu verbinden") { Task { await session.reconnect() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .font(.caption)
            .foregroundStyle(isConnecting ? Color.secondary : Color.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isConnecting: Bool {
        session.phase == .resolving || session.phase == .connecting
    }

    private var disconnectReason: String {
        if case .failed(let reason) = session.phase { return reason }
        if session.phase == .needsPairing { return "Kopplung nötig — zurück zur Instanz-Liste." }
        return "Verbindung getrennt."
    }

    /// Der zuletzt vermerkte Fehler. Vorher landete er nur in `store.lastError` und wurde einzig vom
    /// Markdown-Editor gelesen — ein fehlgeschlagenes Senden war damit vollständig unsichtbar.
    @ViewBuilder private var errorBanner: some View {
        if let error = session.store.lastError {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(error)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("OK") { session.store.clearError() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var composer: some View {
        VStack(spacing: 4) {
            connectionBanner
            errorBanner
            // Status der Spracheingabe (Download/Aufnahme/Transkription/Fehler) — nur wenn relevant.
            if let status = dictation.statusText {
                HStack(spacing: 6) {
                    if dictation.showsSpinner { ProgressView().controlSize(.mini) }
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(dictation.isError ? Color.red : .secondary)
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 8) {
                TextField("Nachricht an den Stream …", text: draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                micButton
                if isStreamActive { stopButton } // laufenden Prozess unterbrechen (wie der Prompt-Stopp in mads)
                Button {
                    // Ziel-Stream beim TAP festhalten: schaltet die Randleiste während des Sendens
                    // um, ginge die Nachricht sonst an den neuen Stream bzw. würde dessen Entwurf leeren.
                    let id = streamId
                    let text = drafts[id] ?? ""
                    Task {
                        // Feld erst leeren, wenn die Nachricht wirklich rausging (sonst geht sie verloren).
                        if await session.sendInput(agentId: id, text: text) {
                            drafts[id] = ""
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                // Ohne stehende Verbindung gesperrt — ein Tipp verpuffte sonst stumm, und der Riegel
                // darüber sagt auch warum. Der Entwurf bleibt dabei erhalten.
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.phase != .live)
            }
        }
        .padding(8)
        .background(.bar)
    }

    /// Arbeitet der Stream gerade aktiv (läuft ein Turn)? Dann ist ein Unterbrechen sinnvoll.
    private var isStreamActive: Bool {
        stream?.status == .running || stream?.status == .starting
    }

    /// Der aktuelle Arbeitsschritt für die Zeile am Ende der Timeline (gleiche Regel wie in mads:
    /// beim Start bzw. ohne gemeldeten Schritt „startet…").
    private func stepLabel(_ stream: Stream) -> String {
        guard stream.status != .starting, let step = stream.currentStep, !step.isEmpty, step != "starting up" else {
            return "startet …"
        }
        return step
    }

    /// Prominenter Stopp-Knopf im Composer — unterbricht den laufenden Turn (wie der Prompt-Stopp in der
    /// Desktop-mads). Nutzt denselben Pfad wie „Unterbrechen" im Menü (interrupt_agent).
    private var stopButton: some View {
        Button {
            Task { await session.interrupt(agentId: streamId) }
        } label: {
            Image(systemName: "stop.circle.fill")
                .font(.title2)
                .foregroundStyle(.red)
        }
        .accessibilityLabel("Laufenden Prozess unterbrechen")
    }

    /// Spracheingabe: tippen startet die lokale Whisper-Diktierung, erneutes Tippen stoppt und fügt
    /// den erkannten Text an den Entwurf an (überschreibt Getipptes nie). Rot + pulsierend bei Aufnahme.
    private var micButton: some View {
        Button {
            Task {
                if dictation.isRecording {
                    if let text = await dictation.stopAndTranscribe(), !text.isEmpty {
                        let current = draft.wrappedValue
                        draft.wrappedValue = current.isEmpty ? text : current + " " + text
                    }
                } else {
                    await dictation.startRecording()
                }
            }
        } label: {
            Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic.fill")
                .font(.title2)
                .foregroundStyle(dictation.isRecording ? Color.red : (dictation.isBusy ? Color.secondary : Color.accentColor))
                .symbolEffect(.pulse, isActive: dictation.isRecording)
        }
        .disabled(dictation.isBusy)
        .accessibilityLabel(dictation.isRecording ? "Diktat stoppen" : "Per Sprache diktieren")
    }

    /// Kopfzeile der Timeline: Status, Verbrauch — und die Betriebsart, unter der dieser Stream
    /// läuft. Sie steht IN der Timeline (scrollt also mit) und kostet damit keinen Dauerplatz; wer
    /// sie ändern will, öffnet das Menü.
    private func header(_ stream: Stream) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                StatusDot(status: stream.status)
                Text(String(describing: stream.status)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(stream.numTurns) Turns · $\(String(format: "%.2f", stream.costUsd))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                chip(ModelCatalog.label(for: stream.model) + (stream.effort.map { " · \($0.label)" } ?? ""))
                if let mode = stream.permissionMode {
                    chip(mode.shortLabel, tone: mode.runsUnattended ? .orange : nil)
                }
                // Gelockerte Sandbox unübersehbar — Gegenstück zum Badge am Mac.
                if stream.role != "integrator", let sandbox = stream.sandboxMode, sandbox != .on {
                    chip(sandbox.shortLabel, symbol: sandbox.symbol, tone: sandbox == .off ? .orange : nil)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.bottom, 4)
    }

    private func chip(_ text: String, symbol: String? = nil, tone: Color? = nil) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9)) }
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(tone ?? .secondary)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background((tone ?? Color.secondary).opacity(0.12), in: Capsule())
    }
}

/// Bild-Anhänge einer Anweisung: das ECHTE Thumbnail (reiste klein im user_text-Event mit), Tippen →
/// gross. Das VOLLBILD liegt nur am Mac auf Platte — `.mads` ist über die Bridge bewusst nicht lesbar,
/// und ein mehrere MB grosses Bild soll nicht durch Ringpuffer/Snapshot-Replay/WSS wandern.
private struct AttachmentThumbs: View {
    let items: [TimelineAttachment]
    @State private var zoomed: TimelineAttachment?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items) { a in
                if let img = Self.image(a) {
                    Button { zoomed = a } label: {
                        Image(uiImage: img)
                            .resizable().scaledToFill()
                            .frame(width: 96, height: 72).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Angehängtes Bild — tippen zum Vergrössern")
                } else {
                    // Kein Thumbnail (z. B. SVG/nicht dekodierbar) → neutraler Hinweis statt leerer Fläche.
                    Text("Bild")
                        .font(.caption2)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }
        }
        .sheet(item: $zoomed) { a in
            ZStack {
                Color.black.ignoresSafeArea()
                if let img = Self.image(a) {
                    Image(uiImage: img).resizable().scaledToFit()
                }
            }
            .onTapGesture { zoomed = nil }
        }
    }

    private static func image(_ a: TimelineAttachment) -> UIImage? {
        guard let b64 = a.thumbBase64, let data = Data(base64Encoded: b64) else { return nil }
        return UIImage(data: data)
    }
}

/// Eine Timeline-Zeile im mads-Look: farbiger Status-Punkt links (`tl-dot`) + Inhalt (`tl-row`).
private struct TimelineItemView: View {
    let item: TimelineItem

    var body: some View {
        if case .user(let text, let attachments) = item.kind {
            // Anweisung vom Menschen: rechtsbündige Akzent-Blase (wie ein gesendeter Chat-Eintrag),
            // darunter die echten Bild-Thumbnails (kamen inline im Event mit).
            HStack {
                Spacer(minLength: 32)
                VStack(alignment: .trailing, spacing: 6) {
                    if !text.isEmpty {
                        Text(markdown(text))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.white)
                    }
                    if !attachments.isEmpty { AttachmentThumbs(items: attachments) }
                }
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(dotColor).frame(width: 7, height: 7).padding(.top, 6)
                content
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .user: EmptyView() // oben separat gerendert
        case .assistant(let text, let via):
            VStack(alignment: .leading, spacing: 2) {
                if let via { SubAgentTag(label: via) }
                Text(markdown(text)) // Markdown wie in mads (fett/kursiv/Code/Links)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .thinking(let text, let via):
            VStack(alignment: .leading, spacing: 2) {
                if let via { SubAgentTag(label: via) }
                Text(text).font(.callout).italic().foregroundStyle(.secondary)
            }
        case .tool(let card):
            ToolCardView(card: card)
        case .todos(let todos):
            TodosView(todos: todos)
        case .notice(let text):
            Text(markdown(text)).font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// Status-Punkt-Farbe (mads `tl-dot`): dim für Text/Thinking/Notice, grün/rot/orange für Tools.
    private var dotColor: Color {
        switch item.kind {
        case .user, .assistant, .thinking, .notice:
            return Color.secondary.opacity(0.5)
        case .todos:
            return .green
        case .tool(let card):
            switch card.ok {
            case .some(true): return .green
            case .some(false): return .red
            case .none: return card.running ? .orange : Color.secondary.opacity(0.5)
            }
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Marke „aufgerufen von einem Teil-Agenten" (mads `tl-tool-via`) — ohne sie sieht die Äusserung
/// bzw. der Aufruf eines Teil-Agenten genauso aus wie einer des Streams selbst.
private struct SubAgentTag: View {
    let label: String

    var body: some View {
        Text("▸ \(label)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }
}

/// Eine Werkzeug-Karte wie in der mads-Timeline: Name + mitgelieferte Beschreibung, darunter das
/// Argument (IN) und das Ergebnis (OUT). Langes Ergebnis wird gekürzt und lässt sich aufklappen
/// (Desktop: „mehr anzeigen" ab 400 Zeichen).
private struct ToolCardView: View {
    let card: ToolCard
    @State private var expanded = false

    private var isLong: Bool { (card.output?.count ?? 0) > 400 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(card.name).font(.system(.footnote, design: .monospaced)).bold()
                if let via = card.viaSubAgent { SubAgentTag(label: via) }
                if card.ok == false { Text("Fehler").font(.caption2).foregroundStyle(.red) }
                Spacer(minLength: 0)
            }
            if let description = card.description, !description.isEmpty {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            if let command = card.command, !command.isEmpty {
                ioBlock(label: "IN", text: command, lineLimit: expanded ? nil : 6)
            }
            if let output = card.output, !output.isEmpty {
                ioBlock(label: "OUT", text: output, lineLimit: expanded || !isLong ? nil : 8)
            }
            if isLong {
                Button(expanded ? "weniger" : "mehr anzeigen") { expanded.toggle() }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Ein IN-/OUT-Block: Kürzel links, monospaced Inhalt auf getöntem Grund. Der Text UMBRICHT
    /// (kein horizontales Scrollen) — auf dem Handy sonst unlesbar.
    private func ioBlock(label: String, text: String, lineLimit: Int?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)      // Befehl/Ausgabe kopierbar (z. B. um sie am Mac zu prüfen)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Die To-do-Liste eines Streams (TodoWrite) — wie am Mac eine eigene Karte statt einer
/// Werkzeug-Zeile, deren Inhalt sonst im rohen JSON-Argument verschwände.
private struct TodosView: View {
    let todos: [TodoItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Todos").font(.system(.footnote, design: .monospaced)).bold()
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                HStack(alignment: .top, spacing: 6) {
                    Text(mark(todo.status)).font(.caption2).foregroundStyle(color(todo.status))
                    Text(todo.content)
                        .font(.caption)
                        .foregroundStyle(todo.status == "completed" ? .secondary : .primary)
                        .strikethrough(todo.status == "completed")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mark(_ status: String) -> String {
        switch status {
        case "completed": return "✓"
        case "in_progress": return "▸"
        default: return "☐"
        }
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "completed": return .green
        case "in_progress": return .orange
        default: return .secondary
        }
    }
}
