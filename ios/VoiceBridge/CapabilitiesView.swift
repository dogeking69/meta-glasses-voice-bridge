import SwiftUI

/// "What I can do" — the assistant's own list of actions, read from the Mac.
///
/// The listener builds this from its config, so your apps, projects and
/// shortcuts appear here by name and nothing is advertised that the Mac would
/// refuse to run. Tap an example to say it.
struct CapabilitiesView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    /// Runs the tapped example back in the conversation.
    let onRun: (String) -> Void

    @State private var capabilities: [ListenerClient.Capability] = []
    @State private var loadFailed: String?
    @State private var isLoading = true
    @State private var search = ""

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadFailed {
                    ContentUnavailableView("Could not reach your Mac", systemImage: "desktopcomputer.trianglebadge.exclamationmark", description: Text(loadFailed))
                } else if matches.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    list
                }
            }
            .navigationTitle("What I can do")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search actions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private var list: some View {
        List {
            ForEach(categories, id: \.self) { category in
                Section(category) {
                    ForEach(matches.filter { $0.category == category }) { capability in
                        row(capability)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ capability: ListenerClient.Capability) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: ActionStyle.icon(for: capability.action))
                    .foregroundStyle(.secondary)
                Text(capability.summary)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if capability.confirm {
                Label("Asks first", systemImage: "checkmark.shield")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            ForEach(capability.examples, id: \.self) { example in
                Button {
                    onRun(example)
                    dismiss()
                } label: {
                    HStack {
                        Text("\u{201C}\(example)\u{201D}")
                            .font(.callout)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.caption2)
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    /// Categories in the order the Mac sent them, not alphabetically — they
    /// are grouped from most to least everyday.
    private var categories: [String] {
        var seen: Set<String> = []
        return matches.map(\.category).filter { seen.insert($0).inserted }
    }

    private var matches: [ListenerClient.Capability] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return capabilities }
        return capabilities.filter { capability in
            capability.summary.lowercased().contains(query)
                || capability.category.lowercased().contains(query)
                || capability.action.replacingOccurrences(of: "_", with: " ").contains(query)
                || capability.examples.contains { $0.lowercased().contains(query) }
        }
    }

    private func load() async {
        guard let baseURL = settings.baseURL, settings.isConfigured else {
            loadFailed = "Set your Mac's address in Settings first."
            isLoading = false
            return
        }
        let client = ListenerClient(baseURL: baseURL, sharedSecret: settings.sharedSecret)
        do {
            capabilities = try await client.capabilities()
        } catch {
            loadFailed = error.localizedDescription
        }
        isLoading = false
    }
}
