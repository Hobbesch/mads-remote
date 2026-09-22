import SwiftUI

/// Liste der mads-Instanzen: gerade im Netz gefundene UND früher gekoppelte. Tippen →
/// verbinden/koppeln (InstanceDetailView).
///
/// Die gemerkten gehören in dieselbe Liste, weil `NWBrowser` ausserhalb des WLAN nichts findet —
/// ohne sie bliebe die Liste unterwegs leer und man käme gar nicht dazu, es über einen Tunnel zu
/// versuchen.
struct InstanceListView: View {
    let browser: InstanceBrowser

    /// Beim Erscheinen frisch gelesen (nicht im `body`): nach einem Pairing steht hier sonst noch
    /// der Stand von vorher.
    @State private var known: [KnownInstance] = []

    private var instances: [DiscoveredInstance] {
        DiscoveredInstance.mergingKnown(browser.instances, known: known)
    }

    var body: some View {
        List {
            if instances.isEmpty {
                ContentUnavailableView {
                    Label("Keine mads-Instanz gefunden", systemImage: "antenna.radiowaves.left.and.right.slash")
                } description: {
                    Text("In mads (im selben WLAN): Einstellungen → Remote aktivieren. Einmal gekoppelte Instanzen erscheinen danach auch von unterwegs.")
                }
            } else {
                ForEach(instances) { instance in
                    NavigationLink {
                        InstanceDetailView(instance: instance)
                    } label: {
                        InstanceRow(instance: instance)
                    }
                }
            }
        }
        .navigationTitle("mads Remote")
        .task { known = KnownInstanceStore.all() }
    }
}

private struct InstanceRow: View {
    let instance: DiscoveredInstance

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(instance.name)
                .font(.headline)
            HStack(spacing: 6) {
                if !instance.project.isEmpty {
                    Text(instance.project)
                }
                if let pv = instance.protocolVersion {
                    Text("· Protokoll v\(pv)")
                }
                if instance.fingerprint != nil {
                    Image(systemName: "lock.fill").font(.caption2)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Ehrlich benennen, woher der Eintrag kommt: nicht im Netz gesehen, sondern gemerkt.
            // Ein Versuch kann also länger dauern oder scheitern, wenn der Mac aus ist.
            if !instance.isDiscovered {
                Label("Gemerkt — nicht im lokalen Netz gefunden", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
