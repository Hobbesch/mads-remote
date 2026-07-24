import AVFoundation
import Foundation
import SwiftUI
// WhisperKit ist noch nicht vollständig Swift-6-Sendable-auditiert. `@preconcurrency` entschärft die
// Sendable-Prüfung für WhisperKit-Typen (u. a. `[TranscriptionResult]`, das eine actor-Grenze quert),
// ohne die strenge Nebenläufigkeit im restlichen Projekt aufzuweichen.
@preconcurrency import WhisperKit

/// Lokale Sprach-zu-Text-Diktierung für den Prompt-Composer — komplett ON-DEVICE über WhisperKit
/// (CoreML/Whisper). Das Modell wird beim ERSTEN Antippen einmalig geladen (Fortschritt sichtbar),
/// danach liegt es im Cache. Kein Netz, keine Cloud, keine Daten verlassen das Gerät.
///
/// Ablauf: `startRecording()` → Mikro aufnehmen → `stopAndTranscribe()` liefert den erkannten Text,
/// den die View in den Entwurf einfügt (ersetzt nichts, hängt an). Alles MainActor-isoliert; die
/// schweren WhisperKit-Calls sind `async` und geben die MainActor während der Rechenzeit frei.
@MainActor
final class DictationController: ObservableObject {
    /// Whisper-Variante im HuggingFace-Repo `argmaxinc/whisperkit-coreml`. `base` ist mehrsprachig,
    /// klein (~150 MB) und schnell — guter Erst-Start. Für maximale Deutsch-Genauigkeit auf neueren
    /// iPhones auf `openai_whisper-large-v3-v20240930_626MB` (~626 MB) hochstellen.
    private let modelVariant = "openai_whisper-base"

    enum Phase: Equatable {
        case idle
        case preparing           // SYNCHRON gesetzt (vor dem ersten await) → sperrt Re-Entry + Knopf
        case downloading(Double) // 0…1 (einmaliger Modell-Download)
        case loading             // Modell in CoreML laden/prewarmen
        case recording
        case transcribing
        case denied              // Mikro-Berechtigung verweigert
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private var whisperKit: WhisperKit?
    private let audioProcessor = AudioProcessor()
    /// Generations-Marke: jeder Start bekommt eine. `cancel()` (oder ein neuer Start) erhöht sie und
    /// entwertet damit den laufenden Start — dessen Phasen-Schreibvorgänge nach jedem await werden zu
    /// No-ops (`set(_:if:)`), sodass ein abgebrochener Start das Mikro NICHT mehr scharfschaltet.
    private var startToken = 0

    /// Phase nur setzen, wenn dieser Start noch der aktuelle ist (sonst hat cancel/ein neuer Start übernommen).
    private func set(_ p: Phase, if token: Int) {
        if token == startToken { phase = p }
    }

    // MARK: – von der View genutzte Ableitungen

    var isRecording: Bool { phase == .recording }

    /// „Beschäftigt" = Mikro-Knopf sperren (Vorbereitung/Download/Load/Transkription laufen).
    var isBusy: Bool {
        switch phase {
        case .preparing, .downloading, .loading, .transcribing: return true
        case .idle, .recording, .denied, .failed: return false
        }
    }

    var showsSpinner: Bool {
        switch phase {
        case .preparing, .loading, .transcribing: return true
        default: return false
        }
    }

    var isError: Bool {
        switch phase {
        case .denied, .failed: return true
        default: return false
        }
    }

    /// Kurze Status-Zeile über dem Composer (nil = nichts anzeigen).
    var statusText: String? {
        switch phase {
        case .idle: return nil
        case .preparing: return "Mikrofon wird vorbereitet …"
        case .recording: return "Aufnahme läuft … tippe zum Stoppen"
        case .downloading(let f): return "Sprachmodell wird geladen … \(Int(f * 100)) %"
        case .loading: return "Sprachmodell wird vorbereitet …"
        case .transcribing: return "Wird transkribiert …"
        case .denied: return "Mikrofon-Zugriff verweigert — in den Einstellungen erlauben."
        case .failed(let m): return m
        }
    }

    // MARK: – Steuerung

    func startRecording() async {
        guard !isRecording, !isBusy else { return }
        // SYNCHRON (vor dem ersten await) beschäftigt markieren + eigene Generation ziehen: ein zweiter
        // schneller Tipp scheitert nun an `!isBusy` und der Knopf ist gesperrt (keine Doppel-Starts).
        startToken &+= 1
        let token = startToken
        phase = .preparing

        // 1) Mikro-Berechtigung (iOS-Systemdialog beim ersten Mal).
        let granted = await AudioProcessor.requestRecordPermission()
        guard token == startToken else { return } // abgebrochen (View verlassen) → nicht scharfschalten
        guard granted else { phase = .denied; return }

        // 2) Modell sicherstellen (nur beim ersten Mal: Download + Load).
        if whisperKit == nil {
            do {
                try await ensureModel(token: token)
            } catch {
                set(.failed("Sprachmodell konnte nicht geladen werden."), if: token)
                return
            }
        }
        // Während des (evtl. langen) Downloads kann cancel() gefeuert haben → dann NICHT aufnehmen.
        guard token == startToken else { return }

        // 3) Audio-Session auf Aufnahme stellen und live mitschneiden (16 kHz mono, WhisperKit-intern).
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: [])
            try audioProcessor.startRecordingLive(callback: nil)
            phase = .recording
        } catch {
            phase = .failed("Aufnahme konnte nicht gestartet werden.")
        }
    }

    /// Laufende Diktierung verwerfen (z. B. beim Verlassen der Ansicht): einen bereits gestarteten,
    /// aber noch ladenden Start ENTWERTEN (Token erhöhen → er schaltet das Mikro nicht mehr scharf) UND
    /// eine schon laufende Aufnahme stoppen + Audio-Session freigeben. Ein laufender Modell-Download darf
    /// zu Ende laufen (füllt nur den Cache); dank Token endet er ohne Aufnahme.
    func cancel() {
        startToken &+= 1 // laufenden Start entwerten
        if isRecording {
            audioProcessor.stopRecording()
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        switch phase {
        case .preparing, .downloading, .loading, .recording: phase = .idle
        case .idle, .transcribing, .denied, .failed: break
        }
    }

    /// Aufnahme stoppen und transkribieren. Liefert den erkannten Text (leer = nichts Verwertbares).
    func stopAndTranscribe() async -> String? {
        guard isRecording else { return nil }
        audioProcessor.stopRecording()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])

        let samples = Array(audioProcessor.audioSamples)
        // < ~0,2 s Audio (WhisperKit nimmt mit 16 kHz auf) → kein sinnvoller Inhalt (Fehl-Tipp).
        let minSamples = 3200 // 0,2 s * 16 000 Hz
        guard samples.count > minSamples, let wk = whisperKit else {
            phase = .idle
            return nil
        }

        phase = .transcribing
        do {
            let options = DecodingOptions(task: .transcribe, language: "de", skipSpecialTokens: true)
            let results = try await wk.transcribe(audioArray: samples, decodeOptions: options)
            phase = .idle
            let text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            phase = .failed("Transkription fehlgeschlagen.")
            return nil
        }
    }

    // MARK: – Modell laden (einmalig)

    private func ensureModel(token: Int) async throws {
        set(.downloading(0), if: token)
        // Fortschritt über einen Sendable-Kanal spiegeln: die Download-Closure darf self NICHT direkt
        // fangen (strenge Nebenläufigkeit) — sie schiebt nur Doubles in einen AsyncStream, den ein
        // MainActor-Task in `phase` überträgt (nur solange dieser Start aktuell + noch im Download ist).
        let (progressStream, continuation) = AsyncStream<Double>.makeStream()
        let mirror = Task { @MainActor in
            for await frac in progressStream {
                if token == startToken, case .downloading = phase { phase = .downloading(frac) }
            }
        }
        defer { continuation.finish(); mirror.cancel() }
        let handler: @Sendable (Progress) -> Void = { p in continuation.yield(p.fractionCompleted) }
        // Idempotent: liegt die Variante schon im Cache, springt der Download sofort auf 100 %.
        let folder = try await WhisperKit.download(variant: modelVariant, progressCallback: handler)
        set(.loading, if: token) // nach cancel() ein No-op → Phase bleibt .idle, kein hängender Zustand
        // Das geladene Modell trotzdem behalten (Cache für den nächsten Start), auch wenn abgebrochen.
        whisperKit = try await WhisperKit(WhisperKitConfig(model: modelVariant, modelFolder: folder.path))
    }
}
