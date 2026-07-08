import SwiftUI

/// Prominentes Banner für offene Berechtigungsanfragen (docs/architecture.md §7.3). Wird NUR durch
/// einen expliziten Tap auf Erlauben/Ablehnen beantwortet — nie automatisch (§6 P3#16).
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

                if req.kind == "ask_user_question" {
                    // Rückfrage (AskUserQuestion) braucht eine Antwort-Auswahl, kein {behavior:"allow"}.
                    // Bis die Frage-UI existiert (Folge-Phase) nur Ablehnen anbieten — nie falsch „erlauben".
                    Text("Rückfrage — bitte direkt an mads beantworten. Hier nur ablehnbar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        Task { await session.answerPermission(agentId: req.agentId, requestId: req.requestId, allow: false) }
                    } label: {
                        Text("Ablehnen").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
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
