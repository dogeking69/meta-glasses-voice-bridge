import CryptoKit
import Foundation

/// Sends the transcribed words to the listener running on your Mac.
///
/// Every request is signed with HMAC-SHA256 over "<timestamp>.<body>" using the
/// shared secret. The Mac recomputes the same signature and rejects anything
/// that does not match or that is more than a minute old, so nothing else on
/// your network can drive your computer.
struct ListenerClient {
    let baseURL: URL
    let sharedSecret: String

    struct Reply: Decodable {
        let ok: Bool
        let action: String?
        let speak: String?
        let error: String?
    }

    func send(transcript: String) async throws -> Reply {
        let body = try JSONEncoder().encode(["transcript": transcript])
        let timestamp = String(Int(Date().timeIntervalSince1970))

        var request = URLRequest(url: baseURL.appendingPathComponent("command"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(signature(timestamp: timestamp, body: body), forHTTPHeaderField: "X-Signature")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ListenerError.badResponse(status: code)
        }
        return reply
    }

    /// Quick check that the Mac is reachable, used by the Settings screen.
    func checkHealth() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 5
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func signature(timestamp: String, body: Data) -> String {
        let key = SymmetricKey(data: Data(sharedSecret.utf8))
        var payload = Data(timestamp.utf8)
        payload.append(0x2E) // "."
        payload.append(body)
        let mac = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    enum ListenerError: LocalizedError {
        case badResponse(status: Int)

        var errorDescription: String? {
            switch self {
            case .badResponse(let status):
                return "Your Mac replied with an unexpected result (HTTP \(status)). Is the listener running?"
            }
        }
    }
}
