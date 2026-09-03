import Foundation
import SwiftUI

/// Everything the chat screen needs: the conversation, the microphone, the
/// hands-free session, and the round trip to the Mac.
@MainActor
final class ChatModel: ObservableObject {
    @Published private(set) var messages: [Message] = []
    @Published private(set) var isThinking = false
    @Published private(set) var pendingId: String?
    /// True from the moment the shutter is asked for until the answer is back.
    @Published private(set) var isLooking = false
    @Published var draft = ""
    @Published var banner: String?

    let capture = VoiceCapture()
    private(set) lazy var session = ListeningSession(capture: capture)
    private let speaker = Speaker()

    private var settings: SettingsStore?
    private var glasses: GlassesManager?
    private var notificationTicker: Timer?

    var hasPendingConfirmation: Bool { pendingId != nil }
    var isRecording: Bool { capture.isRecording }

    /// Shown on an empty conversation. Replaced by real examples from the Mac
    /// once the catalog loads, so they name your own apps and projects.
    @Published private(set) var suggestions = [
        "What's on my calendar?",
        "Open Spotify",
        "Set a timer for 10 minutes",
        "Make a note that…",
        "What am I looking at?"
    ]

    func attach(settings: SettingsStore, glasses: GlassesManager) {
        self.settings = settings
        self.glasses = glasses
        session.onUtterance = { [weak self] text, isConfirmationReply in
            Task { await self?.handleSpoken(text, isConfirmationReply: isConfirmationReply) }
        }
    }

    // MARK: - Loading

    /// Pull a few example phrases out of the Mac's own capability catalog.
    /// One per category keeps the empty state short but broad.
    func loadSuggestions() async {
        guard let client = makeClient(),
              let catalog = try? await client.capabilities() else { return }

        var seenCategories: Set<String> = []
        var picked: [String] = []
        for capability in catalog {
            guard let example = capability.examples.first,
                  seenCategories.insert(capability.category).inserted else { continue }
            picked.append(example)
        }
        if !picked.isEmpty { suggestions = Array(picked.prefix(5)) }
    }

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

            // The camera is on the wearer's face, not on the Mac, so the Mac
            // answers "take a photo and come back to me".
            if reply.capture == true {
                await look(question: reply.question ?? "What am I looking at?")
            }
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

    // MARK: - Looking through the glasses

    /// Tapping the camera button. Anything typed becomes the question.
    func lookNow() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        Task { await look(question: typed.isEmpty ? "What am I looking at?" : typed) }
    }

    /// Take a photo through the glasses and ask the Mac what is in it.
    func look(question: String) async {
        guard let glasses, let client = makeClient() else {
            banner = "Set your Mac's address in Settings."
            return
        }

        isLooking = true
        defer { isLooking = false }
        Haptics.tap()

        do {
            let photo = try await glasses.capturePhoto()
            append(Message(id: UUID().uuidString, role: .user, text: question, photo: photo))

            let reply = try await client.look(question: question, photo: photo)
            let spoken = reply.speak ?? reply.error ?? "I could not tell."
            append(Message(id: UUID().uuidString, role: .assistant, text: spoken,
                           action: "look", ok: reply.ok))
            banner = nil
            resumeListeningAfterSpeaking(awaitingConfirmation: false)
            speaker.say(spoken)
            Haptics.success(reply.ok ? .success : .error)
        } catch {
            let reason = error.localizedDescription
            append(Message(id: UUID().uuidString, role: .assistant, text: reason,
                           action: "look", ok: false))
            resumeListeningAfterSpeaking(awaitingConfirmation: false)
            speaker.say(reason)
            Haptics.success(.error)
        }
    }

    /// Whether the camera button should be offered at all.
    var canTakePhoto: Bool { glasses?.canTakePhoto ?? false }

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
