import Foundation
import SwiftUI

/// Hands-free mode. You squeeze the Action Button once to start a listening
/// session, say the wake phrase whenever you like, and squeeze again to stop.
///
/// It is a *session* rather than always-on for a reason: holding the Bluetooth
/// hands-free link open keeps the glasses in call mode, which drains them fast.
/// A session you switch on for a few minutes costs little; leaving it on all day
/// would roughly halve the battery life of the glasses.
@MainActor
final class ListeningSession: ObservableObject {
    enum Phase: Equatable {
        case off
        /// Listening for the wake phrase.
        case awaitingWake
        /// Wake phrase heard; collecting the command until you stop talking.
        case capturingCommand
        /// A confirmation was read back; your next words are the answer, and no
        /// wake phrase is needed.
        case awaitingConfirmation
        /// Talking to the Mac, or speaking a reply. Not listening.
        case busy
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var startedAt: Date?
    @Published private(set) var heard = ""

    /// Delivered when a full utterance is ready. The flag is true when it is an
    /// answer to a confirmation rather than a new command.
    var onUtterance: ((String, Bool) -> Void)?

    private let capture: VoiceCapture
    private var wakePhrase = WakeWord.defaultPhrase
    private var ticker: Timer?
    private var lastChange = Date()
    private var commandStarted: Date?
    private var confirmationStarted: Date?
    private var recognitionRefreshed = Date()

    /// Stop talking for this long and the command is considered finished.
    private let commandSilence: TimeInterval = 1.3
    /// A single command cannot run longer than this.
    private let commandMaximum: TimeInterval = 20
    /// How long to wait for a spoken yes/no before giving up on it.
    private let confirmationWindow: TimeInterval = 30
    /// A recognition task does not run forever, so it is cycled this often.
    private let recognitionLifetime: TimeInterval = 50

    var isRunning: Bool { phase != .off }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    init(capture: VoiceCapture) {
        self.capture = capture
    }

    // MARK: - Session control

    func start(wakePhrase: String) {
        guard phase == .off else { return }
        self.wakePhrase = wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? WakeWord.defaultPhrase
            : wakePhrase

        capture.onTranscript = { [weak self] text in self?.transcriptChanged(text) }
        do {
            try capture.startStreaming()
        } catch {
            capture.lastError = error.localizedDescription
            return
        }

        startedAt = Date()
        lastChange = Date()
        recognitionRefreshed = Date()
        phase = .awaitingWake
        heard = ""
        startTicker()
        Chime.sessionStarted()
    }

    func stop() {
        if phase != .off { Chime.sessionStopped() }
        ticker?.invalidate()
        ticker = nil
        capture.onTranscript = nil
        capture.stopStreaming()
        phase = .off
        startedAt = nil
        heard = ""
        commandStarted = nil
        confirmationStarted = nil
    }

    func toggle(wakePhrase: String) {
        isRunning ? stop() : start(wakePhrase: wakePhrase)
    }

    // MARK: - Phase changes driven by the rest of the app

    /// Called while the Mac is working or a reply is being spoken. Recognition
    /// pauses so the app does not hear its own voice and re-trigger itself.
    func beginWork() {
        guard isRunning else { return }
        phase = .busy
        capture.stopStreaming()
    }

    /// Work finished. `awaitingConfirmation` skips the wake phrase for the reply.
    func finishWork(awaitingConfirmation: Bool) {
        guard isRunning else { return }
        do {
            try capture.startStreaming()
        } catch {
            capture.lastError = error.localizedDescription
            stop()
            return
        }
        heard = ""
        lastChange = Date()
        recognitionRefreshed = Date()
        commandStarted = nil
        if awaitingConfirmation {
            confirmationStarted = Date()
            phase = .awaitingConfirmation
        } else {
            confirmationStarted = nil
            phase = .awaitingWake
        }
    }

    // MARK: - Internals

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func transcriptChanged(_ text: String) {
        switch phase {
        case .awaitingWake:
            guard let match = WakeWord.find(wakePhrase, in: text) else { return }
            Chime.wakeDetected()
            phase = .capturingCommand
            commandStarted = Date()
            heard = match.remainder
            lastChange = Date()

        case .capturingCommand:
            let remainder = WakeWord.find(wakePhrase, in: text)?.remainder ?? text
            if remainder != heard {
                heard = remainder
                lastChange = Date()
            }

        case .awaitingConfirmation:
            if text != heard {
                heard = text
                lastChange = Date()
            }

        case .off, .busy:
            break
        }
    }

    private func tick() {
        guard isRunning else { return }
        let silence = Date().timeIntervalSince(lastChange)

        switch phase {
        case .awaitingWake:
            // Cycle the recognition task so its transcript does not grow without
            // bound and so it never hits its own time limit mid-sentence.
            if Date().timeIntervalSince(recognitionRefreshed) > recognitionLifetime {
                capture.resetRecognition()
                recognitionRefreshed = Date()
            }

        case .capturingCommand:
            let tooLong = commandStarted.map { Date().timeIntervalSince($0) > commandMaximum } ?? false
            let finished = !heard.isEmpty && silence > commandSilence
            if finished || tooLong {
                emit(heard, isConfirmationReply: false)
            }

        case .awaitingConfirmation:
            if !heard.isEmpty && silence > commandSilence {
                emit(heard, isConfirmationReply: true)
            } else if let started = confirmationStarted,
                      Date().timeIntervalSince(started) > confirmationWindow {
                // No answer came. Drop back to the wake phrase; the pending
                // action on the Mac expires on its own.
                confirmationStarted = nil
                phase = .awaitingWake
                capture.resetRecognition()
                recognitionRefreshed = Date()
            }

        case .off, .busy:
            break
        }
    }

    private func emit(_ text: String, isConfirmationReply: Bool) {
        let utterance = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty else { return }
        Chime.captured()
        beginWork()
        onUtterance?(utterance, isConfirmationReply)
    }
}
