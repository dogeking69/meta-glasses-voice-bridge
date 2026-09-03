import AVFoundation
import Foundation
import Speech
import UserNotifications

/// Microphone plumbing: routes audio from the glasses and turns it into text.
///
/// The glasses microphone reaches iOS as ordinary Bluetooth hands-free (HFP)
/// audio — 8 kHz mono, the same as a phone call. That is why this uses plain
/// AVFoundation instead of the Meta toolkit, which has no microphone API.
///
/// Transcription is Apple's on-device recognizer, so audio never leaves the
/// phone. Two modes are supported: push-to-talk (`startRecording`) and a
/// continuous stream (`startStreaming`) that `ListeningSession` drives.
@MainActor
final class VoiceCapture: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isStreaming = false
    @Published private(set) var transcript = ""
    @Published private(set) var inputRouteName = "—"
    @Published private(set) var usingGlassesMic = false
    @Published var lastError: String?

    /// Fires on every transcript change while streaming.
    var onTranscript: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    // MARK: - Permissions

    /// Microphone, speech recognition and notifications. Call once, early.
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

        // Used for the "listening" notification. Not fatal if refused.
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        return true
    }

    // MARK: - Push to talk

    func startRecording() {
        guard !isRecording, !isStreaming else { return }
        do {
            try beginAudio()
            isRecording = true
        } catch {
            lastError = error.localizedDescription
            teardown()
        }
    }

    /// Stops and returns the final transcript, or nil if nothing was heard.
    func stopRecording() async -> String? {
        guard isRecording else { return nil }
        isRecording = false
        request?.endAudio()

        // Give the recognizer a moment to emit its final, punctuated result.
        try? await Task.sleep(nanoseconds: 700_000_000)

        let final = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        teardown()
        return final.isEmpty ? nil : final
    }

    // MARK: - Continuous streaming

    func startStreaming() throws {
        guard !isStreaming else { return }
        try beginAudio()
        isStreaming = true
    }

    func stopStreaming() {
        guard isStreaming else { return }
        isStreaming = false
        teardown()
    }

    /// Starts a fresh recognition task, clearing the transcript but leaving the
    /// audio engine running. Used after each command, and periodically because
    /// a single recognition task does not run indefinitely.
    func resetRecognition() {
        guard isStreaming else { return }
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        transcript = ""
        do {
            try beginRecognition()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Audio

    private func beginAudio() throws {
        try configureAudioSession()
        transcript = ""
        try beginRecognition()

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        engine.prepare()
        try engine.start()
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()

        // .voiceChat plus Bluetooth HFP is what puts the glasses mic in play.
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
                    self.onTranscript?(self.transcript)
                }
                if let error, self.isRecording {
                    self.lastError = error.localizedDescription
                }
            }
        }
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
