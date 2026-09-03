import Foundation
import Network

/// Finds Macs running the listener, so nobody has to know their own IP address.
///
/// The listener advertises `_voicebridge._tcp` while it runs. Browsing for it
/// needs `NSBonjourServices` in Info.plist to name that exact type — without
/// it iOS reports no error at all, the list simply stays empty forever.
@MainActor
final class MacBrowser: ObservableObject {
    struct Mac: Identifiable, Equatable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    /// Where a Mac actually is, once its advert has been resolved.
    struct Address {
        let host: String
        let port: Int
    }

    @Published private(set) var macs: [Mac] = []
    @Published private(set) var isSearching = false
    /// Set when the browser itself fails, which is nearly always a missing
    /// `NSBonjourServices` entry or local network permission being refused.
    @Published private(set) var failure: String?

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_voicebridge._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Mac? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return Mac(name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in
                // One Mac can be advertised on several interfaces at once, so
                // the same name arrives more than once.
                var seen = Set<String>()
                self?.macs = found.filter { seen.insert($0.name).inserted }
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isSearching = true
                    self?.failure = nil
                case .failed(let error):
                    self?.isSearching = false
                    self?.failure = error.localizedDescription
                case .cancelled:
                    self?.isSearching = false
                default:
                    break
                }
            }
        }

        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        macs = []
        isSearching = false
    }

    /// Turn an advert into an address we can actually post to.
    ///
    /// Bonjour hands back a service name, not a host. Opening a connection and
    /// reading back the path it took is the shortest honest way to learn where
    /// that service lives.
    /// `nonisolated` because Network calls its handlers on its own queue, not
    /// on the main actor.
    nonisolated static func resolve(_ endpoint: NWEndpoint, timeout: TimeInterval = 5) async -> Address? {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let once = Once()

        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ address: Address?) {
                once.run {
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: address)
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(address(of: connection.currentPath?.remoteEndpoint))
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    nonisolated private static func address(of endpoint: NWEndpoint?) -> Address? {
        guard case let .hostPort(host, port) = endpoint else { return nil }
        let number = Int(port.rawValue)

        switch host {
        case .ipv4(let value):
            // Addresses come back with an interface suffix, like "%en0".
            return Address(host: trimmed("\(value)"), port: number)
        case .ipv6(let value):
            return Address(host: "[\(trimmed("\(value)"))]", port: number)
        case .name(let value, _):
            return Address(host: value, port: number)
        @unknown default:
            return nil
        }
    }

    nonisolated private static func trimmed(_ address: String) -> String {
        String(address.split(separator: "%").first ?? "")
    }

    /// Guards a continuation that several callbacks can reach.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false

        func run(_ body: () -> Void) {
            lock.lock()
            let first = !used
            used = true
            lock.unlock()
            if first { body() }
        }
    }
}
