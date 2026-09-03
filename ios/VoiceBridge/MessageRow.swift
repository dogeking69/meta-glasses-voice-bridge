import SwiftUI

/// One message. User turns sit right in a tinted bubble; replies run full width
/// with a small action badge, which keeps long answers readable.
struct MessageRow: View {
    let message: Message
    let onRepeat: (Message) -> Void

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantBlock
        case .confirmation: confirmationBlock
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)
            Text(message.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .foregroundStyle(.white)
                .contextMenu {
                    Button("Say again", systemImage: "arrow.clockwise") { onRepeat(message) }
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = message.text
                    }
                }
        }
    }

    private var assistantBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label = ActionStyle.label(for: message.action) {
                HStack(spacing: 5) {
                    Image(systemName: ActionStyle.icon(for: message.action))
                    Text(label)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(message.ok ? Color.secondary : Color.orange)
            }

            Text(message.text)
                .foregroundStyle(message.ok ? Color.primary : Color.orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = message.text
            }
        }
    }

    private var confirmationBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("needs your OK")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)

            Text(message.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35))
        )
    }
}

/// The three animated dots shown while the Mac is working.
struct ThinkingRow: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { index in
                Circle()
                    .frame(width: 7, height: 7)
                    .foregroundStyle(.secondary)
                    .opacity(opacity(for: index))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                phase = 3
            }
        }
    }

    private func opacity(for index: Int) -> Double {
        let distance = abs(phase - Double(index))
        return 0.3 + 0.7 * max(0, 1 - distance)
    }
}
