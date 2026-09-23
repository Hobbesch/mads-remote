import SwiftUI

/// Schmale Randleiste zum Umschalten zwischen den Streams EINES Repos.
///
/// Warum am Rand und nicht als Navigations-Ebene: das Umschalten ist die häufigste Bewegung am
/// Gerät (ein Repo hat schnell fünf Streams), und der Weg „zurück zur Liste → anderer Stream →
/// wieder scrollen" kostete jedes Mal drei Schritte und die Scroll-Position. Die Leiste schaltet in
/// der Ansicht selbst um — `StreamDetailView` tauscht nur die id aus, der Navigations-Stapel wächst
/// dabei nicht.
///
/// Der Preis sind 44 pt Breite. Dafür trägt sie zwei Dinge, die sonst unsichtbar wären: den Status
/// JEDES Streams (Punkt) und — wichtiger — den roten Punkt an einem Stream, der auf eine
/// Entscheidung wartet. Vorher merkte man eine Eskalation im Nachbar-Stream nur über die
/// Benachrichtigung oder gar nicht.
struct StreamRail: View {
    let session: InstanceSession
    @Binding var selected: String
    /// Tap auf „+". Der Aufrufer öffnet das Sheet — die Leiste kennt es nicht, sie meldet nur.
    let onNewStream: () -> Void

    private var store: InstanceStore { session.store }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(store.order, id: \.self) { id in
                        if let stream = store.streams[id] {
                            item(stream)
                        }
                    }
                    newStreamButton
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
            }
            // Wechsel von aussen (z. B. Tap in der Streams-Liste) → die Kachel in Sicht holen.
            .onChange(of: selected) { _, new in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(new, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
        }
        .frame(width: 44)
        .background(.bar)
    }

    /// „+" am Ende der Leiste: einen weiteren Sub-Stream eröffnen. Ohne stehende Verbindung
    /// gesperrt — ein Tap verpuffte sonst stumm, genau wie es beim Senden schon einmal der Fall war.
    private var newStreamButton: some View {
        Button(action: onNewStream) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(session.phase == .live ? Color.accentColor : .secondary)
                .frame(width: 36, height: 38)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(session.phase != .live)
        .accessibilityLabel("Neuen Stream starten")
    }

    private func item(_ stream: Stream) -> some View {
        let isSelected = stream.id == selected
        let needsDecision = store.permissions.contains { $0.agentId == stream.id }
        return Button {
            selected = stream.id
        } label: {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 3) {
                    marker(stream)
                    StatusDot(status: stream.status)
                }
                .frame(width: 36, height: 38)
                .background(
                    isSelected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
                // Wartet auf eine Entscheidung → roter Punkt, auch wenn der Stream nicht offen ist.
                if needsDecision {
                    Circle()
                        .fill(.red)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 1.5))
                        .offset(x: 4, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .id(stream.id)
        .accessibilityLabel(accessibilityLabel(stream, needsDecision: needsDecision))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// Der Integrator bekommt sein Merge-Zeichen (es gibt genau einen, und er ist der einzige, der
    /// nach main mergen darf); Sub-Streams zwei Buchstaben aus ihrem Namen.
    @ViewBuilder private func marker(_ stream: Stream) -> some View {
        if stream.role == "integrator" {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(stream.id == selected ? Color.accentColor : .secondary)
        } else {
            Text(Self.initials(stream.label ?? stream.id))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(stream.id == selected ? Color.accentColor : .secondary)
        }
    }

    private func accessibilityLabel(_ stream: Stream, needsDecision: Bool) -> String {
        var parts = [stream.label ?? stream.id, String(describing: stream.status)]
        if needsDecision { parts.append("wartet auf eine Entscheidung") }
        return parts.joined(separator: ", ")
    }

    /// Zwei Buchstaben aus dem Stream-Namen: bei mehreren Wörtern deren Anfangsbuchstaben
    /// („auth fix" → „AF"), sonst die ersten beiden Zeichen. Der `mads/`-Branch-Präfix fliegt raus —
    /// er ist bei jedem Stream gleich und trüge nichts zur Unterscheidung bei.
    static func initials(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: "mads/", with: "")
        let words = cleaned.split { !$0.isLetter && !$0.isNumber }
        if words.count >= 2 {
            return String(words.prefix(2).compactMap(\.first)).uppercased()
        }
        let head = String(cleaned.prefix(2)).uppercased()
        return head.isEmpty ? "?" : head
    }
}
