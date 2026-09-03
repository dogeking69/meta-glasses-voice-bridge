import Foundation

/// One line in the conversation. A single turn on the Mac becomes two of these:
/// what you said, and what came back.
struct Message: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
        /// A confirmation waiting on you, styled differently.
        case confirmation
    }

    let id: String
    let role: Role
    var text: String
    var action: String?
    var ok: Bool = true
    var date: Date = Date()

    static func from(_ turn: ListenerClient.Turn) -> [Message] {
        var out: [Message] = []
        if !turn.transcript.isEmpty {
            out.append(Message(id: turn.id + ".u", role: .user, text: turn.transcript, date: turn.date))
        }
        let body = turn.ok ? turn.reply : turn.error
        if !body.isEmpty {
            out.append(Message(id: turn.id + ".a", role: .assistant, text: body,
                               action: turn.action, ok: turn.ok, date: turn.date))
        }
        return out
    }
}

/// Icons and labels for the action badge under an assistant reply.
enum ActionStyle {
    static func icon(for action: String?) -> String {
        switch action {
        case "open_app": return "app.badge"
        case "claude_code": return "chevron.left.forwardslash.chevron.right"
        case "take_note": return "square.and.pencil"
        case "set_reminder": return "bell"
        case "set_timer": return "timer"
        case "get_status": return "info.circle"
        case "system_control": return "slider.horizontal.3"
        case "search_web": return "magnifyingglass"
        case "open_url": return "safari"
        case "clipboard": return "doc.on.clipboard"
        case "send_message": return "message"
        case "cancelled": return "xmark.circle"
        default: return "sparkles"
        }
    }

    static func label(for action: String?) -> String? {
        guard let action, action != "ask_claude" else { return nil }
        return action.replacingOccurrences(of: "_", with: " ")
    }
}
