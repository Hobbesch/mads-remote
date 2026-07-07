import SwiftUI

/// Pairing: einmaligen PIN aus mads eingeben ODER den QR scannen (docs/mads-bridge.md, OE-R4).
struct PairingView: View {
    let session: InstanceSession
    @State private var pin = ""
    @State private var showScanner = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Gerät koppeln")
                .font(.title2).bold()
            Text("PIN aus mads eingeben (Einstellungen → Remote → Gerät koppeln) oder den QR-Code scannen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
                .font(.system(.title, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 180)

            Button("Koppeln") { Task { await session.submitPin(pin) } }
                .buttonStyle(.borderedProminent)
                .disabled(pin.count < 6)

            Button {
                showScanner = true
            } label: {
                Label("QR-Code scannen", systemImage: "qrcode.viewfinder")
            }
        }
        .padding()
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                QRScannerView { scanned in
                    showScanner = false
                    if let payload = PairingPayload.parse(scanned) {
                        Task { await session.submitPin(payload.pin) }
                    }
                }
                .ignoresSafeArea()
                .navigationTitle("QR scannen")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { showScanner = false } } }
            }
        }
    }
}
