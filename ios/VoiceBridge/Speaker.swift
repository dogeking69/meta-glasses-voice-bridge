import AVFoundation

/// Reads Claude's reply aloud. Because the audio session is already routed to
/// the glasses, this comes out of the glasses speakers rather than the phone.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()

    /// Called when speech ends. Hands-free mode waits for this before it starts
    /// listening again, so the app never hears its own voice.
    var onFinish: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func say(_ text: String) {
        guard !text.isEmpty else {
            onFinish?()
            return
        }

        let session = AVAudioSession.sharedInstance()
        // Playback-only mode with A2DP gives clearer audio than the 8 kHz
        // recording route the microphone uses.
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetoothA2DP, .duckOthers])
        try? session.setActive(true)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onFinish?() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onFinish?() }
    }
}
