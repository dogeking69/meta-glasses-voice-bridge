import SwiftUI

/// The whole app: one conversation, a compact status strip, and a composer that
/// takes either typing or your voice.
struct ChatScreen: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var glasses: GlassesManager
    @StateObject private var model = ChatModel()

    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var draftFocused: Bool

    @State private var showingSettings = false
    @State private var showingStatus = false
    @State private var permissionsGranted = false
    @State private var macReachable: Bool?
    @State private var confirmingClear = false
    @State private var showingSessions = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusStrip
                Divider().opacity(0.4)
                transcript
                composer
            }
            .navigationTitle("Jarvis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItems }
            .sheet(isPresented: $showingSettings, onDismiss: { Task { await refreshMac() } }) {
                SettingsView().environmentObject(settings)
            }
            .sheet(isPresented: $showingSessions) {
                SessionsView().environmentObject(settings)
            }
            .confirmationDialog("Clear the conversation?",
                                isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { Task { await model.clearHistory() } }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This also clears the context used to understand follow-up questions.")
            }
            .task {
                model.attach(settings: settings)
                permissionsGranted = await model.requestPermissions()
                glasses.start()
                if !settings.isConfigured { showingSettings = true }
                await model.loadHistory()
                await refreshMac()
                consumePendingIntent()
            }
            .onChange(of: scenePhase) { _ in consumePendingIntent() }
        }
    }

    // MARK: - Status

    private var statusStrip: some View {
        Button {
            withAnimation(.snappy) { showingStatus.toggle() }
        } label: {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    pill(micLabel, systemImage: "mic.fill", good: model.capture.usingGlassesMic)
                    pill(macLabel, systemImage: "desktopcomputer", good: macReachable == true)
                    if model.session.isRunning {
                        pill("listening", systemImage: "waveform", good: true)
                    }
                    Spacer()
                    Image(systemName: showingStatus ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if showingStatus {
                    VStack(spacing: 6) {
                        detailRow("Glasses", glasses.statusText)
                        detailRow("Microphone", model.capture.inputRouteName)
                        detailRow("Mac", macLabel)
                        detailRow("Wake phrase", settings.effectiveWakePhrase)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let error = glasses.lastError ?? model.capture.lastError ?? model.banner {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    private func pill(_ text: String, systemImage: String, good: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text).lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(good ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12),
                    in: Capsule())
        .foregroundStyle(good ? Color.green : Color.secondary)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
        }
        .font(.caption)
    }

    private var micLabel: String {
        model.capture.usingGlassesMic ? "glasses" : "phone"
    }

    private var macLabel: String {
        guard settings.isConfigured else { return "not set up" }
        switch macReachable {
        case .some(true): return "connected"
        case .some(false): return "unreachable"
        case nil: return "checking"
        }
    }

    // MARK: - Conversation

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.messages.isEmpty && !model.isThinking {
                        emptyState
                    }
                    ForEach(model.messages) { message in
                        MessageRow(message: message, onRepeat: model.repeatMessage)
                            .id(message.id)
                    }
                    if model.isThinking {
                        ThinkingRow().id("thinking")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages.count) { _ in scrollDown(proxy) }
            .onChange(of: model.isThinking) { _ in scrollDown(proxy) }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask anything, or tell your Mac what to do.")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 40)

            ForEach(model.suggestions, id: \.self) { suggestion in
                Button {
                    model.send(suggestion)
                } label: {
                    HStack {
                        Text(suggestion)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.caption)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Color.secondary.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 10) {
            if model.hasPendingConfirmation { confirmationButtons }

            HStack(spacing: 10) {
                TextField("Message", text: $model.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($draftFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.secondary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .onSubmit(model.sendDraft)
                    .disabled(!canSend)

                if model.draft.isEmpty {
                    micButton
                } else {
                    Button(action: model.sendDraft) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                    }
                    .disabled(!canSend)
                }
            }

            handsFreeButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }

    private var micButton: some View {
        Image(systemName: model.isRecording ? "waveform.circle.fill" : "mic.circle.fill")
            .font(.system(size: 32))
            .foregroundStyle(model.isRecording ? Color.red : Color.accentColor)
            .scaleEffect(model.isRecording ? 1.15 : 1)
            .animation(.spring(duration: 0.2), value: model.isRecording)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if canSend { model.startRecording() } }
                    .onEnded { _ in Task { await model.finishRecording() } }
            )
            .accessibilityLabel("Hold to talk")
    }

    private var confirmationButtons: some View {
        HStack(spacing: 10) {
            Button("Cancel", role: .cancel) {
                Task { await model.answerConfirmation(.no) }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)

            Button("Confirm") {
                Task { await model.answerConfirmation(.yes) }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
    }

    private var handsFreeButton: some View {
        Button {
            model.toggleHandsFree()
        } label: {
            Label(
                model.session.isRunning
                    ? "Listening — say \"\(settings.effectiveWakePhrase)\""
                    : "Start hands-free",
                systemImage: model.session.isRunning ? "stop.circle.fill" : "waveform.circle"
            )
            .font(.footnote.weight(.medium))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(model.session.isRunning ? .red : .accentColor)
        .disabled(!canSend)
    }

    private var canSend: Bool {
        permissionsGranted && settings.isConfigured && !model.isThinking
    }

    // MARK: - Toolbar and lifecycle

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                confirmingClear = true
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .disabled(model.messages.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Claude Code sessions", systemImage: "chevron.left.forwardslash.chevron.right") {
                    showingSessions = true
                }
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func refreshMac() async {
        macReachable = await model.checkMac()
    }

    private func consumePendingIntent() {
        guard PendingIntent.toggleRequested else { return }
        PendingIntent.toggleRequested = false
        model.toggleHandsFree()
    }
}
