import UIKit
import UserNotifications

/// The "I am listening" banner.
///
/// Deliberately a plain local notification rather than a Live Activity: it needs
/// no second Xcode target and works today. It is replaced in place as the
/// session runs, so only one ever sits in Notification Centre.
enum ListeningNotification {
    private static let identifier = "voicebridge.listening"

    static func show(phase: ListeningSession.Phase, elapsed: TimeInterval, wakePhrase: String, glassesMic: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title(for: phase, wakePhrase: wakePhrase)
        content.body = body(elapsed: elapsed, glassesMic: glassesMic)
        content.sound = nil
        content.interruptionLevel = .passive

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func clear() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private static func title(for phase: ListeningSession.Phase, wakePhrase: String) -> String {
        switch phase {
        case .awaitingWake: return "Listening — say \"\(wakePhrase)\""
        case .capturingCommand: return "Listening to your command…"
        case .awaitingConfirmation: return "Waiting for yes or no"
        case .busy: return "Working…"
        case .off: return "Voice Bridge"
        }
    }

    /// Elapsed time stands in for glasses battery, which the Meta toolkit no
    /// longer exposes to third-party apps. Time with the hands-free link open is
    /// what actually predicts the drain, so it is the more useful number anyway.
    private static func body(elapsed: TimeInterval, glassesMic: Bool) -> String {
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        let clock = String(format: "%d:%02d", minutes, seconds)

        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        let phone = level < 0 ? "—" : "\(Int(level * 100))%"

        let mic = glassesMic ? "glasses mic" : "iPhone mic"
        return "\(clock) listening · \(mic) · iPhone battery \(phone)"
    }
}
