import SwiftUI

/// Everything the Mac has done, in order. Pulled from the listener rather than
/// stored on the phone, so it survives reinstalls and matches what actually ran.
struct ChatView: View {
    @EnvironmentObject private var settings: SettingsStore

    @State private var turns: [ListenerClient.Turn] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var confirmingClear = false

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    message(loadError, systemImage: "exclamationmark.triangle")
                } else if turns.isEmpty && !isLoading {
                    message("Nothing yet. Hold the talk button or say your wake phrase.",
                            systemImage: "bubble.left.and.bubble.right")
                } else {
                    list
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        confirmingClear = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(turns.isEmpty)
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .confirmationDialog("Clear all history?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { Task { await clear() } }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This also clears the context Claude uses to understand follow-up questions.")
            }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(turns) { turn in
                    TurnRow(turn: turn).id(turn.id)
                }
            }
            .listStyle(.plain)
            .onChange(of: turns.count) { _ in
                if let last = turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func message(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }

    private func load() async {
        guard let baseURL = settings.baseURL, settings.isConfigured else {
            loadError = "Set your Mac's address in Settings first."
            return
        }
        isLoading = true
        defer { isLoading = false }

        let client = ListenerClient(baseURL: baseURL, sharedSecret: settings.sharedSecret)
        do {
            turns = try await client.history()
            loadError = nil
        } catch {
            loadError = "Could not reach your Mac. Is the listener running?"
        }
    }

    private func clear() async {
        guard let baseURL = settings.baseURL else { return }
        let client = ListenerClient(baseURL: baseURL, sharedSecret: settings.sharedSecret)
        _ = try? await client.clearHistory()
        await load()
    }
}

/// One exchange: what you said, what ran, what came back.
private struct TurnRow: View {
    let turn: ListenerClient.Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(turn.transcript)
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                Text(turn.date, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(label)
                    .font(.caption2.monospaced())
            }
            .foregroundStyle(turn.ok ? .secondary : Color.orange)

            Text(turn.ok ? turn.reply : turn.error)
                .font(.footnote)
                .foregroundStyle(turn.ok ? .primary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    private var label: String {
        turn.action.replacingOccurrences(of: "_", with: " ")
    }

    private var icon: String {
        switch turn.action {
        case "open_app": return "app.badge"
        case "claude_code": return "chevron.left.forwardslash.chevron.right"
        case "take_note": return "square.and.pencil"
        case "set_reminder": return "bell"
        case "get_status": return "info.circle"
        case "system_control": return "slider.horizontal.3"
        case "search_web": return "magnifyingglass"
        case "cancelled": return "xmark.circle"
        default: return "bubble.left"
        }
    }
}
