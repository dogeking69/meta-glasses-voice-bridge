import AVFoundation
import Foundation
import Speech

/// Records from the glasses microphone and turns it into text on the device.
///
/// The glasses microphone reaches iOS as a normal Bluetooth hands-free (HFP)
/// audio input — 8 kHz mono, the same as a phone call. That is why this class
/// uses plain AVFoundation instead of the Meta toolkit: the toolkit has no
/// microphone API.
///
/// Transcription uses Apple's on-device speech recognizer, so nothing is sent
/// to a server here and no API key is involved.
@MainActor
final class VoiceCapture: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var inputRouteName = "—"
    @Published private(set) var usingGlassesMic = false
    @Published var lastError: String?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Ask for microphone and speech permissions. Call once, early.
    func requestPermissions() async -> Bool {
        let mic: Bool
        if #available(iOS 17.0, *) {
            mic = await AVAudioApplication.requestRecordPermission()
        } else {
            mic = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
        }
        guard mic else {
            lastError = "Microphone access denied. Enable it in Settings."
            return false
        }

        let speech: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else {
            lastError = "Speech recognition denied. Enable it in Settings."
            return false
        }
        return true
    }

    func startRecording() {
        guard !isRecording else { return }
        lastError = nil
        transcript = ""

        do {
            try configureAudioSession()
            try beginRecognition()
            isRecording = true
        } catch {
            lastError = error.localizedDescription
            teardown()
        }
    }

    /// Stops recording and returns the final transcript, or nil if nothing was heard.
    func stopRecording() async -> String? {
        guard isRecording else { return nil }
        isRecording = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()

        // Give the recognizer a moment to emit its final, punctuated result.
        try? await Task.sleep(nanoseconds: 700_000_000)

        let final = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        teardown()
        return final.isEmpty ? nil : final
    }

    // MARK: - Audio routing

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()

        // .voiceChat + Bluetooth HFP is what puts the glasses mic in play.
        // Without the Bluetooth option iOS silently falls back to the iPhone mic.
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        if let hfp = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            try session.setPreferredInput(hfp)
        }

        let input = session.currentRoute.inputs.first
        inputRouteName = input?.portName ?? "Unknown"
        usingGlassesMic = (input?.portType == .bluetoothHFP)
    }

    // MARK: - Recognition

    private func beginRecognition() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw CaptureError.recognizerUnavailable
        }

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            newRequest.requiresOnDeviceRecognition = true
        }
        request = newRequest

        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if let error, self.isRecording {
                    self.lastError = error.localizedDescription
                }
            }
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            newRequest.append(buffer)
        }

        engine.prepare()
        try engine.start()
    }

    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        task?.cancel()
        task = nil
        request = nil
    }

    enum CaptureError: LocalizedError {
        case recognizerUnavailable

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable:
                return "Speech recognition is not available right now. Check your network or language settings."
            }
        }
    }
}
