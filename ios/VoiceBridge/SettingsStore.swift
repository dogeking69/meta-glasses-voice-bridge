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
        static let macName = "listener.macName"
        static let otherHosts = "listener.otherHosts"
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

    /// The name of the paired Mac, purely so the Settings screen can say which
    /// computer this is. Empty when the address was typed in by hand.
    @Published var macName: String {
        didSet { UserDefaults.standard.set(macName, forKey: Keys.macName) }
    }

    /// The other addresses pairing found for the same Mac — `.local`, LAN and
    /// Tailscale — offered as one-tap alternatives when the current one stops
    /// answering.
    @Published var otherHosts: [String] {
        didSet { UserDefaults.standard.set(otherHosts, forKey: Keys.otherHosts) }
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
        macName = UserDefaults.standard.string(forKey: Keys.macName) ?? ""
        otherHosts = UserDefaults.standard.stringArray(forKey: Keys.otherHosts) ?? []
    }

    /// Take everything a successful pairing handed back.
    ///
    /// The Mac lists its addresses best first, so the first one becomes the
    /// address in use and the rest are kept as alternatives.
    func adopt(_ result: Pairing.Result) {
        let addresses = (result.addresses ?? []).filter { !$0.isEmpty }
        guard let best = addresses.first, let secret = result.sharedSecret else { return }

        host = best
        otherHosts = Array(addresses.dropFirst())
        if let paired = result.port { port = String(paired) }
        sharedSecret = secret
        macName = result.name ?? ""
    }

    /// Switch to one of the other addresses, keeping the old one on the list.
    func useHost(_ address: String) {
        guard address != host else { return }
        var rest = otherHosts.filter { $0 != address }
        rest.append(host)
        host = address
        otherHosts = rest
    }

    /// Falls back to the default if the field is left empty.
    var effectiveWakePhrase: String {
        let trimmed = wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? WakeWord.defaultPhrase : trimmed
    }

    /// Find an address of this Mac that answers, switching to it if the one in
    /// use has gone quiet. True when one of them worked.
    func recoverAddress() async -> Bool {
        guard let portNumber = Int(port) else { return false }
        let candidates = [host] + otherHosts
        guard let winner = await ListenerClient.firstReachable(hosts: candidates, port: portNumber) else {
            return false
        }
        useHost(winner)
        return true
    }

    var isConfigured: Bool {
        !host.isEmpty && !sharedSecret.isEmpty && Int(port) != nil
    }

    var baseURL: URL? {
        guard let portNumber = Int(port) else { return nil }
        return URL(string: "http://\(host):\(portNumber)")
    }
}
