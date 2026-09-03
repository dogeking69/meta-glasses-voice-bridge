import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var glasses: GlassesManager
    @EnvironmentObject private var settings: SettingsStore

    @StateObject private var capture = VoiceCapture()
    @State private var speaker = Speaker()

    @State private var status = "Hold the button and speak."
    @State private var reply = ""
    @State private var isSending = false
    @State private var permissionsGranted = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                statusPanel
                Spacer()
                transcriptPanel
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
                    .foregroundStyle(.blue)
                    .multilineTextAlignment(.center)
            }
        }
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
            await send(transcript)
        }
    }

    private func send(_ transcript: String) async {
        guard let baseURL = settings.baseURL else {
            status = "Set your Mac's address in Settings."
            return
        }

        isSending = true
        defer { isSending = false }

        let client = ListenerClient(baseURL: baseURL, sharedSecret: settings.sharedSecret)
        do {
            let result = try await client.send(transcript: transcript)
            let spoken = result.speak ?? result.error ?? "Done."
            reply = spoken
            status = result.ok ? (result.action ?? "Done.") : "Something went wrong."
            speaker.say(spoken)
        } catch {
            reply = ""
            status = error.localizedDescription
        }
    }
}
