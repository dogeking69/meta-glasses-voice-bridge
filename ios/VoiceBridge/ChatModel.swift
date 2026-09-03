import Foundation
import SwiftUI

/// Everything the chat screen needs: the conversation, the microphone, the
/// hands-free session, and the round trip to the Mac.
@MainActor
final class ChatModel: ObservableObject {
    @Published private(set) var messages: [Message] = []
    @Published private(set) var isThinking = false
    @Published private(set) var pendingId: String?
    @Published var draft = ""
    @Published var banner: String?

    let capture = VoiceCapture()
    private(set) lazy var session = ListeningSession(capture: capture)
    private let speaker = Speaker()

    private var settings: SettingsStore?
    private var notificationTicker: Timer?

    var hasPendingConfirmation: Bool { pendingId != nil }
    var isRecording: Bool { capture.isRecording }

    /// Shown on an empty conversation. Chosen to demonstrate the range.
    let suggestions = [
        "What's on my calendar?",
        "Open Spotify",
        "Set a timer for 10 minutes",
        "Make a note that…",
        "Turn the volume down"
    ]

    func attach(settings: SettingsStore) {
        self.settings = settings
        session.onUtterance = { [weak self] text, isConfirmationReply in
            Task { await self?.handleSpoken(text, isConfirmationReply: isConfirmationReply) }
        }
    }

    // MARK: - Loading

    func loadHistory() async {
        guard let client = makeClient() else { return }
        guard let turns = try? await client.history() else { return }
        // Server history is the source of truth, but never clobber an
        // in-flight exchange the user is still looking at.
        guard !isThinking, pendingId == nil else { return }
        messages = turns.flatMap(Message.from)
    }

    func clearHistory() async {
        guard let client = makeClient() else { return }
        _ = try? await client.clearHistory()
        messages = []
    }

    // MARK: - Sending

    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await submit(text) }
    }

    func send(_ text: String) {
        Task { await submit(text) }
    }

    /// Re-run something already in the conversation.
    func repeatMessage(_ message: Message) {
        guard message.role == .user else { return }
        send(message.text)
    }

    private func submit(_ text: String) async {
        append(Message(id: UUID().uuidString, role: .user, text: text))

        if pendingId != nil {
            await answerConfirmation(SpokenDecision.parse(text), transcript: text)
        } else {
            await perform { try await $0.send(transcript: text) }
        }
    }

    private func handleSpoken(_ text: String, isConfirmationReply: Bool) async {
        append(Message(id: UUID().uuidString, role: .user, text: text))
        if isConfirmationReply, pendingId != nil {
            await answerConfirmation(SpokenDecision.parse(text), transcript: text)
        } else {
            await perform { try await $0.send(transcript: text) }
        }
    }

    func answerConfirmation(_ decision: ListenerClient.Decision, transcript: String? = nil) async {
        guard let id = pendingId else { return }
        pendingId = nil
        await perform { try await $0.confirm(pendingId: id, decision: decision, transcript: transcript) }
    }

    private func perform(_ call: (ListenerClient) async throws -> ListenerClient.Reply) async {
        guard let client = makeClient() else {
            banner = "Set your Mac's address in Settings."
            return
        }

        isThinking = true
        defer { isThinking = false }
        Haptics.tap()

        do {
            let reply = try await call(client)
            let spoken = reply.speak ?? reply.error ?? "Done."
            let awaitingConfirmation = reply.needsConfirmation == true

            pendingId = awaitingConfirmation ? reply.pendingId : nil
            append(Message(
                id: UUID().uuidString,
                role: awaitingConfirmation ? .confirmation : .assistant,
                text: spoken,
                action: reply.action,
                ok: reply.ok
            ))
            banner = nil

            resumeListeningAfterSpeaking(awaitingConfirmation: awaitingConfirmation)
            speaker.say(spoken)
            Haptics.success(awaitingConfirmation ? .warning : .success)
        } catch {
            pendingId = nil
            append(Message(id: UUID().uuidString, role: .assistant,
                           text: error.localizedDescription, ok: false))
            resumeListeningAfterSpeaking(awaitingConfirmation: false)
            speaker.say("")
            Haptics.success(.error)
        }
    }

    private func append(_ message: Message) {
        messages.append(message)
    }

    // MARK: - Microphone

    func startRecording() {
        guard !session.isRunning else { return }
        Haptics.tap()
        speaker.stop()
        capture.startRecording()
    }

    func finishRecording() async {
        guard capture.isRecording else { return }
        guard let text = await capture.stopRecording() else {
            banner = "I did not catch that."
            return
        }
        await submit(text)
    }

    // MARK: - Hands-free

    func toggleHandsFree() {
        guard let settings else { return }
        if session.isRunning {
            session.stop()
            notificationTicker?.invalidate()
            notificationTicker = nil
            ListeningNotification.clear()
        } else {
            session.start(wakePhrase: settings.effectiveWakePhrase)
            refreshNotification()
            notificationTicker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                Task { @MainActor in self.refreshNotification() }
            }
        }
    }

    private func refreshNotification() {
        guard session.isRunning, let settings else { return }
        ListeningNotification.show(
            phase: session.phase,
            elapsed: session.elapsed,
            wakePhrase: settings.effectiveWakePhrase,
            glassesMic: capture.usingGlassesMic
        )
    }

    /// Recognition stays paused until the spoken reply finishes, otherwise the
    /// app hears its own voice say the wake phrase and loops.
    private func resumeListeningAfterSpeaking(awaitingConfirmation: Bool) {
        guard session.isRunning else { return }
        speaker.onFinish = { [weak self] in
            self?.session.finishWork(awaitingConfirmation: awaitingConfirmation)
            self?.refreshNotification()
        }
    }

    // MARK: - Helpers

    private func makeClient() -> ListenerClient? {
        guard let settings, settings.isConfigured, let baseURL = settings.baseURL else { return nil }
        return ListenerClient(baseURL: baseURL, sharedSecret: settings.sharedSecret)
    }

    func requestPermissions() async -> Bool {
        await capture.requestPermissions()
    }

    func checkMac() async -> Bool? {
        guard let client = makeClient() else { return nil }
        return await client.checkHealth()
    }
}
