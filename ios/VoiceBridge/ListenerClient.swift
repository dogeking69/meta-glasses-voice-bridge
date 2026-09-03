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
        /// True when the Mac has NOT run anything yet and is reading the action
        /// back for you to approve.
        let needsConfirmation: Bool?
        let pendingId: String?
        /// True when the Mac wants a photo before it can answer. The camera is
        /// on your face, not on the Mac, so it has to ask.
        let capture: Bool?
        /// What to answer about the photo once it has been taken.
        let question: String?
    }

    /// What you said in reply to a spoken confirmation.
    enum Decision: String {
        case yes, no, edit
    }

    func send(transcript: String) async throws -> Reply {
        try await post(path: "command", fields: ["transcript": transcript])
    }

    /// Answer a pending confirmation. `transcript` carries the correction when
    /// the decision is `.edit`.
    func confirm(pendingId: String, decision: Decision, transcript: String? = nil) async throws -> Reply {
        var fields = ["pending_id": pendingId, "decision": decision.rawValue]
        if let transcript { fields["transcript"] = transcript }
        return try await post(path: "confirm", fields: fields)
    }

    /// Send a photo from the glasses along with the question to answer about it.
    ///
    /// The image goes as base64 inside the signed JSON body, so it is covered
    /// by the same HMAC as everything else rather than riding in unsigned.
    func look(question: String, photo: Data) async throws -> Reply {
        try await post(
            path: "look",
            fields: ["question": question, "image_b64": photo.base64EncodedString()],
            timeout: 180
        )
    }

    private func post(path: String, fields: [String: String],
                      timeout: TimeInterval = 90) async throws -> Reply {
        let body = try JSONEncoder().encode(fields)
        let timestamp = String(Int(Date().timeIntervalSince1970))

        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(signature(timestamp: timestamp, body: body), forHTTPHeaderField: "X-Signature")

        let (data, response) = try await URLSession.shared.data(for: request)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let reply = try? decoder.decode(Reply.self, from: data) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ListenerError.badResponse(status: code)
        }
        return reply
    }

    struct Turn: Decodable, Identifiable {
        let id: String
        let transcript: String
        let action: String
        let reply: String
        let ok: Bool
        let error: String
        let at: Double

        var date: Date { Date(timeIntervalSince1970: at) }
    }

    private struct HistoryReply: Decodable {
        let ok: Bool
        let turns: [Turn]
    }

    /// Everything the Mac has done, newest last.
    func history() async throws -> [Turn] {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        var request = URLRequest(url: baseURL.appendingPathComponent("history"))
        request.timeoutInterval = 20
        request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
        // Signed over an empty body, matching the listener.
        request.setValue(signature(timestamp: timestamp, body: Data()), forHTTPHeaderField: "X-Signature")

        let (data, response) = try await URLSession.shared.data(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let reply = try? decoder.decode(HistoryReply.self, from: data) else {
            throw ListenerError.badResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return reply.turns
    }

    // MARK: - Claude Code sessions

    struct SessionSummary: Decodable, Identifiable {
        let id: String
        let title: String
        let project: String
        let messages: Int
        let modified: Double

        var date: Date { Date(timeIntervalSince1970: modified) }
    }

    struct SessionTurn: Decodable, Identifiable {
        let role: String
        let text: String
        let at: Double
        var id: String { "\(role)-\(at)-\(text.prefix(24))" }
        var isUser: Bool { role == "user" }
    }

    struct SessionDetail: Decodable {
        let id: String
        let title: String
        let project: String
        let turns: [SessionTurn]
    }

    private struct SessionsReply: Decodable { let sessions: [SessionSummary] }
    private struct SessionReply: Decodable { let session: SessionDetail }

    func sessions() async throws -> [SessionSummary] {
        try await signedGet(path: "sessions", as: SessionsReply.self).sessions
    }

    func session(id: String) async throws -> SessionDetail {
        try await signedGet(path: "sessions/\(id)", as: SessionReply.self).session
    }

    private func signedGet<T: Decodable>(path: String, as type: T.Type) async throws -> T {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 45
        request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(signature(timestamp: timestamp, body: Data()), forHTTPHeaderField: "X-Signature")

        let (data, response) = try await URLSession.shared.data(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let decoded = try? decoder.decode(T.self, from: data) else {
            throw ListenerError.badResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return decoded
    }

    // MARK: - Capabilities

    /// One thing the assistant can do, as the Mac describes it.
    struct Capability: Decodable, Identifiable {
        let action: String
        let category: String
        let summary: String
        let examples: [String]
        /// True when this is read back to you before it runs.
        let confirm: Bool

        var id: String { action }
    }

    private struct CapabilitiesReply: Decodable { let capabilities: [Capability] }

    /// What this Mac will actually do, with your own apps, projects and
    /// shortcuts already filled in. Asked for rather than hardcoded, so the
    /// list cannot drift from what the listener allows.
    func capabilities() async throws -> [Capability] {
        try await signedGet(path: "capabilities", as: CapabilitiesReply.self).capabilities
    }

    func clearHistory() async throws -> Reply {
        try await post(path: "history/clear", fields: [:])
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
