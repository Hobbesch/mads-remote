import SwiftUI

/// Prominentes Banner für offene Berechtigungsanfragen (docs/architecture.md §7.3). Wird NUR durch
/// einen expliziten Tap auf Erlauben/Ablehnen/Antwort senden beantwortet — nie automatisch (§6 P3#16).
struct PermissionBanner: View {
    let session: InstanceSession
    /// nil = alle Streams (Übersicht); sonst nur die Anfragen DIESES Streams (Detail-Ansicht).
    var agentId: String? = nil

    private var requests: [PermissionRequestInfo] {
        let all = session.store.permissions
        return agentId == nil ? all : all.filter { $0.agentId == agentId }
    }

    var body: some View {
        ForEach(requests, id: \.requestId) { req in
            PermissionCard(session: session, req: req, streamLabel: session.store.streams[req.agentId]?.label)
        }
    }
}

/// Eine Anfrage-Karte mit demselben Informationsgehalt wie der Desktop-Dialog (`PermissionDialog.tsx`):
/// WER fragt (Stream-Name statt roher id), WAS getan werden soll (abgeleiteter Satz), der ROHE
/// Befehl/Pfad, warum gefragt wird und welche Befehls-Kategorie betroffen ist.
private struct PermissionCard: View {
    let session: InstanceSession
    let req: PermissionRequestInfo
    let streamLabel: String?

    @State private var expanded = false

    /// Menschliche Labels der Bash-Kategorien (Port von `shared/safe-command.ts`). Sie stehen am Mac
    /// im „Immer erlauben"-Knopf; hier sind sie die Einordnung der Aktion.
    private static let kindLabels: [String: String] = [
        "danger": "destruktive Befehle",
        "outward": "Push/PR/Merge nach aussen",
        "network": "Netzwerkzugriff nach aussen",
        "pkg": "Paket-/Dienst-Verwaltung",
        "secret": "Zugriff auf Secrets/Config",
        "git": "Git-Fernaktionen (lesend)",
        "write": "Schreiben ausserhalb des Projekts",
        "tool": "dieses Tool",
    ]

    /// Kategorien, die der Desktop „merken" darf (`REMEMBERABLE_KINDS` + `tool`). Aus der Ferne gibt
    /// es das bewusst NICHT: die Bridge streicht `decision.remember` aus jeder Antwort (RB-AUTH-1),
    /// eine dauerhafte Freigabe wäre sonst eine Remote-RCE. Ein Hinweis erklärt den fehlenden Knopf.
    private static let rememberableKinds: Set<String> = ["tool", "network", "pkg", "secret", "git", "write"]

    private var isQuestion: Bool { req.kind == "ask_user_question" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isQuestion, let questions = req.questions, !questions.isEmpty {
                // Rückfrage MIT übermittelten Optionen → aus der Ferne beantworten.
                QuestionForm(session: session, req: req, questions: questions)
            } else if isQuestion {
                // Rückfrage ohne Optionen (alte mads-Version / kaputte Payload) → nur ablehnbar.
                Text("Rückfrage ohne übermittelte Optionen — hier nur ablehnbar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                denyButton.buttonStyle(.bordered)
            } else {
                toolDetails
                HStack {
                    denyButton.buttonStyle(.bordered)
                    Button {
                        Task { await session.answerPermission(agentId: req.agentId, requestId: req.requestId, allow: true) }
                    } label: {
                        Text("Erlauben").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.4)))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("\(streamLabel ?? req.agentId) braucht eine Entscheidung", systemImage: "exclamationmark.shield.fill")
                .font(.subheadline).bold()
            Text(isQuestion ? "Rückfrage" : "Tool-Erlaubnis · \(req.toolName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Der Inhalt, der bisher fehlte: was getan werden soll, der rohe Befehl, der Grund der Rückfrage.
    @ViewBuilder private var toolDetails: some View {
        Text(req.summary)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

        if let command = req.command, !command.isEmpty, command != req.summary {
            Text(command)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(expanded ? nil : 8)   // ein Write-Input kann eine ganze Datei sein
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(7)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                .onTapGesture { expanded.toggle() }
                .accessibilityHint(expanded ? "Tippen zum Einklappen" : "Tippen zum vollständig Anzeigen")
        }

        if let reason = req.decisionReason, !reason.isEmpty {
            detailLine(reason)
        }
        if let path = req.blockedPath, !path.isEmpty {
            detailLine("Pfad: \(path)")
        }
        if let kind = req.commandKind, let label = Self.kindLabels[kind] {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption2)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(kindTint(kind).opacity(0.18), in: Capsule())
                    .foregroundStyle(kindTint(kind))
                Spacer(minLength: 0)
            }
            if Self.rememberableKinds.contains(kind) {
                // Erklärt, warum hier ein Knopf fehlt, den der Mac hat — statt ihn wirkungslos anzubieten.
                Text("„Immer erlauben“ nur am Mac — aus der Ferne bewusst gesperrt.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func detailLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `danger`/`outward` optisch hervorheben — das sind die Fälle, die man auf dem Handy nicht
    /// beiläufig durchwinken soll.
    private func kindTint(_ kind: String) -> Color {
        switch kind {
        case "danger": return .red
        case "outward", "secret": return .orange
        default: return .secondary
        }
    }

    private var denyButton: some View {
        Button(role: .destructive) {
            Task { await session.answerPermission(agentId: req.agentId, requestId: req.requestId, allow: false) }
        } label: {
            Text("Ablehnen").frame(maxWidth: .infinity)
        }
    }
}

/// Interaktives AskUserQuestion-Formular: je Frage eine Option wählen (oder „Etwas anderes…" mit Freitext),
/// dann „Antwort senden". Baut exakt die `answers`-Map des Desktop-Dialogs (Schlüssel = Fragetext).
private struct QuestionForm: View {
    let session: InstanceSession
    let req: PermissionRequestInfo
    let questions: [AskQuestion]

    /// Sentinel für „Etwas anderes…" (Freitext statt einer angebotenen Option) — wie im Desktop.
    private static let custom = "__custom__"

    @State private var picks: [String: String] = [:]       // Fragetext → gewähltes Label (oder Sentinel)
    @State private var customText: [String: String] = [:]  // Fragetext → Freitext bei „Etwas anderes…"
    @State private var sending = false

    /// Effektive Antwort je Frage: bei „Etwas anderes…" der getippte Freitext, sonst das Label.
    private func effective(_ q: AskQuestion) -> String {
        picks[q.question] == Self.custom
            ? (customText[q.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            : (picks[q.question] ?? "")
    }

    private var allAnswered: Bool {
        questions.allSatisfy { q in
            guard let p = picks[q.question] else { return false }
            return p != Self.custom || !(customText[q.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(questions.enumerated()), id: \.offset) { _, q in
                VStack(alignment: .leading, spacing: 6) {
                    if let h = q.header, !h.isEmpty {
                        Text(h.uppercased()).font(.caption2).bold().foregroundStyle(.secondary)
                    }
                    Text(q.question).font(.callout).bold()

                    ForEach(Array(q.options.enumerated()), id: \.offset) { _, o in
                        optionRow(label: o.label, description: o.description, chosen: picks[q.question] == o.label) {
                            picks[q.question] = o.label
                        }
                    }
                    // „Etwas anderes…": eigene Antwort/Anweisung, falls keine Option passt.
                    optionRow(label: "Etwas anderes…", description: "Eigene Antwort/Anweisung eingeben.",
                              chosen: picks[q.question] == Self.custom) {
                        picks[q.question] = Self.custom
                    }
                    if picks[q.question] == Self.custom {
                        TextField("Deine Antwort für diese Frage …", text: Binding(
                            get: { customText[q.question] ?? "" },
                            set: { customText[q.question] = $0 }), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)
                    }
                }
            }

            HStack {
                Button(role: .destructive) {
                    Task { await session.answerPermission(agentId: req.agentId, requestId: req.requestId, allow: false) }
                } label: {
                    Text("Ablehnen").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(sending)

                Button {
                    sending = true
                    var answers: [String: String] = [:]
                    for q in questions { answers[q.question] = effective(q) }
                    Task {
                        await session.answerQuestions(agentId: req.agentId, requestId: req.requestId, answers: answers)
                        sending = false
                    }
                } label: {
                    Text(sending ? "Senden …" : "Antwort senden").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!allAnswered || sending)
            }
        }
    }

    @ViewBuilder
    private func optionRow(label: String, description: String?, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(chosen ? Color.accentColor : Color.secondary)
                    .font(.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.callout).foregroundStyle(.primary)
                    if let d = description, !d.isEmpty {
                        Text(d).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(chosen ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(chosen ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.25)))
        }
        .buttonStyle(.plain)
    }
}
