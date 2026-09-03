import Foundation

/// Turns a spoken reply to a confirmation into yes, no, or an edit.
///
/// Deliberately strict: only a short, unambiguous phrase counts as yes or no.
/// Everything else — including "no, use the other project" — is treated as an
/// edit, which asks you again rather than running anything. The failure
/// direction is always "ask again", never "run it anyway".
enum SpokenDecision {
    static let yesPhrases: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "confirm", "confirmed",
        "correct", "affirmative", "do it", "go ahead", "run it", "send it",
        "yes please", "go for it", "sounds good", "that's right"
    ]

    static let noPhrases: Set<String> = [
        "no", "nope", "cancel", "stop", "abort", "never mind", "nevermind",
        "don't", "do not", "no thanks", "forget it", "scrap it"
    ]

    static func parse(_ spoken: String) -> ListenerClient.Decision {
        let normalized = spoken
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !".,!?".contains($0) }
            .trimmingCharacters(in: .whitespaces)

        if yesPhrases.contains(normalized) { return .yes }
        if noPhrases.contains(normalized) { return .no }
        return .edit
    }
}
