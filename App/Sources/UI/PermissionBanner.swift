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
            VStack(alignment: .leading, spacing: 8) {
                Label("Berechtigung angefragt", systemImage: "exclamationmark.shield.fill")
                    .font(.subheadline).bold()
                Text("Stream \(req.agentId) — Tool: \(req.toolName)")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if req.kind == "ask_user_question", let questions = req.questions, !questions.isEmpty {
                    // Rückfrage MIT übermittelten Optionen → aus der Ferne beantworten.
                    QuestionForm(session: session, req: req, questions: questions)
                } else if req.kind == "ask_user_question" {
                    // Rückfrage ohne Optionen (alte mads-Version / kaputte Payload) → nur ablehnbar.
                    Text("Rückfrage ohne übermittelte Optionen — hier nur ablehnbar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        Task { await session.answerPermission(agentId: req.agentId, requestId: req.requestId, allow: false) }
                    } label: {
                        Text("Ablehnen").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    // Tool-Erlaubnis: Ablehnen / Erlauben.
                    HStack {
                        Button(role: .destructive) {
                            Task { await session.answerPermission(agentId: req.agentId, requestId: req.requestId, allow: false) }
                        } label: {
                            Text("Ablehnen").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

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
