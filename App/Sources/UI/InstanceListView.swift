import SwiftUI

/// Liste der gefundenen mads-Instanzen. Tippen → verbinden/koppeln (InstanceDetailView).
struct InstanceListView: View {
    let browser: InstanceBrowser

    var body: some View {
        List {
            if browser.instances.isEmpty {
                ContentUnavailableView {
                    Label("Keine mads-Instanz gefunden", systemImage: "antenna.radiowaves.left.and.right.slash")
                } description: {
                    Text("Starte mads mit MADS_REMOTE_BRIDGE=1 im selben WLAN.")
                }
            } else {
                ForEach(browser.instances) { instance in
                    NavigationLink {
                        InstanceDetailView(instance: instance)
                    } label: {
                        InstanceRow(instance: instance)
                    }
                }
            }
        }
        .navigationTitle("mads Remote")
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
        }
        .padding(.vertical, 2)
    }
}
