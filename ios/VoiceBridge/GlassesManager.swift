import Foundation

#if canImport(MWDATCore)
import MWDATCore
#endif

/// Wraps the Meta Wearables Device Access Toolkit.
///
/// Important: the toolkit does NOT expose the glasses microphone. Registering
/// here is what pairs your app with the glasses and keeps a session alive;
/// the actual audio arrives over standard Bluetooth hands-free audio, which
/// `VoiceCapture` handles. The app still records and works if this reports
/// "not connected" — you just lose the session status shown on screen.
@MainActor
final class GlassesManager: ObservableObject {
    @Published var registrationText = "Unknown"
    @Published var isRegistered = false
    @Published var deviceCount = 0
    @Published var sessionActive = false
    @Published var lastError: String?

    /// False when the MWDATCore package has not been added to the project yet.
    var toolkitAvailable: Bool {
        #if canImport(MWDATCore)
        return true
        #else
        return false
        #endif
    }

    #if canImport(MWDATCore)
    private var session: DeviceSession?
    private var watchers: [Task<Void, Never>] = []
    #endif

    func start() {
        #if canImport(MWDATCore)
        guard watchers.isEmpty else { return }

        watchers.append(Task { [weak self] in
            for await state in Wearables.shared.registrationStateStream() {
                guard let self else { return }
                self.registrationText = Self.describe(state)
                self.isRegistered = (state == .registered)
                if self.isRegistered { self.openSession() }
            }
        })

        watchers.append(Task { [weak self] in
            for await devices in Wearables.shared.devicesStream() {
                self?.deviceCount = devices.count
            }
        })
        #else
        registrationText = "Toolkit not installed"
        #endif
    }

    func register() {
        #if canImport(MWDATCore)
        Task {
            do {
                // Hands off to the Meta AI app; the user approves there and is
                // sent back to us through our URL scheme.
                try await Wearables.shared.startRegistration()
                lastError = nil
            } catch {
                lastError = "Registration failed: \(error)"
            }
        }
        #else
        lastError = "Add the MWDATCore package in Xcode first. See README."
        #endif
    }

    #if canImport(MWDATCore)
    private func openSession() {
        guard session == nil else { return }

        let newSession: DeviceSession
        do {
            newSession = try Wearables.shared.createSession(
                deviceSelector: AutoDeviceSelector(wearables: Wearables.shared)
            )
            try newSession.start()
        } catch {
            lastError = "Could not start glasses session: \(error)"
            return
        }
        session = newSession

        watchers.append(Task { [weak self] in
            for await state in newSession.stateStream() {
                self?.sessionActive = (state == .started)
            }
        })
    }

    /// RegistrationState has no user-facing text of its own.
    private static func describe(_ state: RegistrationState) -> String {
        switch state {
        case .unavailable: return "Meta AI app unavailable"
        case .available: return "Ready to connect"
        case .registering: return "Connecting…"
        case .registered: return "Connected"
        @unknown default: return "Unknown"
        }
    }
    #endif
}
