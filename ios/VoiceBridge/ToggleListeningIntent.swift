import AppIntents

/// Lets the Action Button, Siri and Shortcuts start and stop a listening
/// session. Map it in Settings → Action Button → Shortcut → Voice Bridge.
@available(iOS 16.0, *)
struct ToggleListeningIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Voice Bridge Listening"
    static var description = IntentDescription(
        "Starts or stops listening for the wake phrase through your glasses."
    )

    /// The audio session and speech recognizer need the app in the foreground to
    /// start reliably, so this brings it up rather than running silently.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingIntent.toggleRequested = true
        return .result()
    }
}

/// Set by the intent, read by the app once it is on screen. A plain flag rather
/// than a notification so it survives the app being launched cold by the intent.
@MainActor
enum PendingIntent {
    static var toggleRequested = false
}

@available(iOS 16.0, *)
struct VoiceBridgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleListeningIntent(),
            phrases: [
                "Start listening with \(.applicationName)",
                "Toggle \(.applicationName)"
            ],
            shortTitle: "Toggle Listening",
            systemImageName: "waveform"
        )
    }
}
