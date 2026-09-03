import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var glasses: GlassesManager
    @EnvironmentObject private var settings: SettingsStore

    @StateObject private var capture = VoiceCapture()
    @State private var speaker = Speaker()

    @State private var status = "Hold the button and speak."
    @State private var reply = ""
    /// Set when the Mac is waiting for you to approve an action. Nothing has run.
    @State private var pending: (id: String, text: String)?
    @State private var isSending = false
    @State private var permissionsGranted = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                statusPanel
                Spacer()
                transcriptPanel
                if pending != nil { confirmationPanel }
                Spacer()
                talkButton
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 34)
            }
            .padding()
            .navigationTitle("Voice Bridge")
            .toolbar {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView().environmentObject(settings)
            }
            .task {
                permissionsGranted = await capture.requestPermissions()
                glasses.start()
                if !settings.isConfigured { showingSettings = true }
            }
        }
    }

    // MARK: - Pieces

    private var statusPanel: some View {
        VStack(spacing: 8) {
            row("Glasses",
                value: glasses.toolkitAvailable ? glasses.registrationText : "Toolkit not added",
                good: glasses.sessionActive)
            row("Microphone",
                value: capture.inputRouteName,
                good: capture.usingGlassesMic)
            row("Mac",
                value: settings.isConfigured ? "\(settings.host):\(settings.port)" : "Not set up",
                good: settings.isConfigured)

            if glasses.toolkitAvailable && !glasses.isRegistered {
                Button("Connect glasses", action: glasses.register)
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }

            if let error = glasses.lastError ?? capture.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    private func row(_ label: String, value: String, good: Bool) -> some View {
        HStack {
            Circle()
                .fill(good ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.footnote)
    }

    private var transcriptPanel: some View {
        VStack(spacing: 12) {
            if !capture.transcript.isEmpty {
                Text(capture.transcript)
                    .font(.title3)
                    .multilineTextAlignment(.center)
            }
            if !reply.isEmpty {
                Text(reply)
                    .font(.body)
                    .foregroundStyle(pending == nil ? .blue : .orange)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
    }

    /// Shown while an action is waiting on you. Say yes, say no, say what to
    /// change — or use these buttons if speaking is awkward.
    private var confirmationPanel: some View {
        VStack(spacing: 10) {
            Label("Waiting for your OK", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.orange)

            HStack(spacing: 12) {
                Button("Cancel", role: .cancel) {
                    Task { await respond(.no) }
                }
                .buttonStyle(.bordered)

                Button("Confirm") {
                    Task { await respond(.yes) }
                }
                .buttonStyle(.borderedProminent)
            }

            Text("Or hold the button and say yes, no, or what to change.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var talkButton: some View {
        Circle()
            .fill(capture.isRecording ? Color.red : Color.accentColor)
            .frame(width: 150, height: 150)
            .overlay {
                if isSending {
                    ProgressView().tint(.white).scaleEffect(1.5)
                } else {
                    Image(systemName: capture.isRecording ? "waveform" : "mic.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(.white)
                }
            }
            .scaleEffect(capture.isRecording ? 1.08 : 1.0)
            .animation(.spring(duration: 0.2), value: capture.isRecording)
            .opacity(canTalk ? 1 : 0.4)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in beginTalking() }
                    .onEnded { _ in endTalking() }
            )
            .allowsHitTesting(canTalk)
    }

    private var canTalk: Bool {
        permissionsGranted && settings.isConfigured && !isSending
    }

    // MARK: - Actions

    private func beginTalking() {
        guard !capture.isRecording, canTalk else { return }
        speaker.stop()
        reply = ""
        status = "Listening…"
        capture.startRecording()
    }

    private func endTalking() {
        guard capture.isRecording else { return }
        status = "Thinking…"

        Task {
            guard let transcript = await capture.stopRecording() else {
                status = "I did not catch that. Try again."
                return
            }
            if pending != nil {
                await respond(SpokenDecision.parse(transcript), transcript: transcript)
            } else {
                await send(transcript)
            }
        }
    }

    private func send(_ transcript: String) async {
        await perform { try await $0.send(transcript: transcript) }
    }

    /// Answer a pending confirmation, by voice or by button.
    private func respond(_ decision: ListenerClient.Decision, transcript: String? = nil) async {
        guard let pendingId = pending?.id else { return }
        pending = nil
        status = decision == .edit ? "Rethinking…" : "Working…"
        await perform {
            try await $0.confirm(pendingId: pendingId, decision: decision, transcript: transcript)
        }
    }

    private func perform(_ call: (ListenerClient) async throws -> ListenerClient.Reply) async {
        guard let baseURL = settings.baseURL else {
            status = "Set your Mac's address in Settings."
            return
        }

        isSending = true
        defer { isSending = false }

        let client = ListenerClient(baseURL: baseURL, sharedSecret: settings.sharedSecret)
        do {
            let result = try await call(client)
            let spoken = result.speak ?? result.error ?? "Done."
            reply = spoken

            if result.needsConfirmation == true, let id = result.pendingId {
                // Nothing has run. Read it back and wait.
                pending = (id: id, text: spoken)
                status = "Say yes, no, or what to change."
            } else {
                pending = nil
                status = result.ok ? (result.action ?? "Done.") : "Something went wrong."
            }
            speaker.say(spoken)
        } catch {
            pending = nil
            reply = ""
            status = error.localizedDescription
        }
    }
}
