import Foundation

/// Where your Mac lives on the network, and the secret shared with it.
///
/// The address is not sensitive so it lives in UserDefaults. The shared secret
/// goes to the Keychain and never appears in source code or backups in plain text.
@MainActor
final class SettingsStore: ObservableObject {
    private enum Keys {
        static let host = "listener.host"
        static let port = "listener.port"
        static let secret = "listener.secret"
        static let wakePhrase = "listener.wakePhrase"
    }

    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: Keys.host) }
    }

    @Published var port: String {
        didSet { UserDefaults.standard.set(port, forKey: Keys.port) }
    }

    @Published var sharedSecret: String {
        didSet { Keychain.set(sharedSecret, for: Keys.secret) }
    }

    /// What you say to wake it up in hands-free mode.
    @Published var wakePhrase: String {
        didSet { UserDefaults.standard.set(wakePhrase, forKey: Keys.wakePhrase) }
    }

    init() {
        host = UserDefaults.standard.string(forKey: Keys.host) ?? ""
        port = UserDefaults.standard.string(forKey: Keys.port) ?? "8765"
        sharedSecret = Keychain.get(Keys.secret)
        wakePhrase = UserDefaults.standard.string(forKey: Keys.wakePhrase) ?? WakeWord.defaultPhrase
    }

    /// Falls back to the default if the field is left empty.
    var effectiveWakePhrase: String {
        let trimmed = wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? WakeWord.defaultPhrase : trimmed
    }

    var isConfigured: Bool {
        !host.isEmpty && !sharedSecret.isEmpty && Int(port) != nil
    }

    var baseURL: URL? {
        guard let portNumber = Int(port) else { return nil }
        return URL(string: "http://\(host):\(portNumber)")
    }
}
