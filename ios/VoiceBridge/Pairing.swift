import Foundation

/// Collects the Mac's address and shared secret with a six-digit PIN.
///
/// This is the one request the app makes unsigned, because the signing key is
/// what it is asking for. The Mac only answers while a pairing window is open
/// there, gives up after five wrong PINs, and refuses callers from outside the
/// local network.
enum Pairing {
    struct Result: Decodable {
        let ok: Bool
        let error: String?
        let name: String?
        let port: Int?
        /// Every way to reach that Mac, best first: `.local`, LAN, Tailscale.
        let addresses: [String]?
        let sharedSecret: String?
    }

    enum PairingError: LocalizedError {
        case unreachable
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .unreachable:
                return "Could not reach that Mac. Is the listener still running?"
            case .refused(let reason):
                return reason
            }
        }
    }

    static func claim(pin: String, host: String, port: Int) async throws -> Result {
        guard let url = URL(string: "http://\(host):\(port)/pair") else {
            throw PairingError.unreachable
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["pin": pin])

        guard let (data, _) = try? await URLSession.shared.data(for: request) else {
            throw PairingError.unreachable
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let result = try? decoder.decode(Result.self, from: data) else {
            throw PairingError.unreachable
        }
        guard result.ok, let secret = result.sharedSecret, !secret.isEmpty else {
            throw PairingError.refused(result.error ?? "That Mac would not pair.")
        }
        return result
    }
}
