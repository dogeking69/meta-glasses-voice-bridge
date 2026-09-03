import SwiftUI

/// Browse the Claude Code conversations stored on your Mac.
///
/// These are read straight from ~/.claude/projects on the Mac. Conversations
/// from the Claude app or claude.ai are not here — they live on Anthropic's
/// servers with no local copy, so nothing on your Mac can read them.
struct SessionsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var sessions: [ListenerClient.SessionSummary] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var search = ""

    private var filtered: [ListenerClient.SessionSummary] {
        guard !search.isEmpty else { return sessions }
        return sessions.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || $0.project.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    EmptyState(title: "Could not load",
                               systemImage: "exclamationmark.triangle",
                               detail: loadError)
                } else if filtered.isEmpty {
                    EmptyState(title: "No conversations",
                               systemImage: "bubble.left.and.bubble.right",
                               detail: "Nothing found on your Mac.")
                } else {
                    list
                }
            }
            .navigationTitle("Claude Code")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search conversations")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private var list: some View {
        List(filtered) { session in
            NavigationLink {
                SessionDetailView(summary: session).environmentObject(settings)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Label(session.project, systemImage: "folder")
                            .lineLimit(1)
                        Text("\(session.messages) messages")
                        Spacer()
                        Text(session.date, format: .relative(presentation: .named))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.plain)
    }

    private func load() async {
        guard let baseURL = settings.baseURL, settings.isConfigured else {
            loadError = "Set your Mac's address in Settings first."
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }

        let client = ListenerClient(baseURL: baseURL, sharedSecret: settings.sharedSecret)
        do {
            sessions = try await client.sessions()
            loadError = nil
        } catch {
            loadError = "Could not reach your Mac. Is the listener running?"
        }
    }
}

/// One conversation, rendered like the chat screen.
struct SessionDetailView: View {
    let summary: ListenerClient.SessionSummary
    @EnvironmentObject private var settings: SettingsStore

    @State private var turns: [ListenerClient.SessionTurn] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(turns) { turn in
                            turnView(turn)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(summary.project)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder
    private func turnView(_ turn: ListenerClient.SessionTurn) -> some View {
        if turn.isUser {
            HStack {
                Spacer(minLength: 40)
                Text(turn.text)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(Color.accentColor,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
            }
        } else {
            Text(turn.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func load() async {
        guard let baseURL = settings.baseURL else { isLoading = false; return }
        defer { isLoading = false }
        let client = ListenerClient(baseURL: baseURL, sharedSecret: settings.sharedSecret)
        turns = (try? await client.session(id: summary.id)) .map(\.turns) ?? []
    }
}

/// ContentUnavailableView is iOS 17 only and this app targets iOS 16.
private struct EmptyState: View {
    let title: String
    let systemImage: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
