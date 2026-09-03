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
                guard let self else { return }
                self.deviceCount = devices.count
                // Glasses often connect after registration finishes. Without
                // this, a session is never attempted again and the app sits
                // there registered but with nothing to talk to.
                if self.isRegistered && !devices.isEmpty && !self.sessionActive {
                    self.openSession()
                }
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
            lastError = Self.explain(error)
            return
        }
        session = newSession
        lastError = nil

        watchers.append(Task { [weak self] in
            for await state in newSession.stateStream() {
                self?.sessionActive = (state == .started)
            }
        })

        watchers.append(Task { [weak self] in
            for await error in newSession.errorStream() {
                guard let self else { return }
                self.lastError = Self.explain(error)
                // A dead session must be cleared or it blocks every retry.
                self.session = nil
                self.sessionActive = false
            }
        })
    }

    /// DeviceSessionError cases are terse. Say what to actually do about them.
    private static func explain(_ error: Error) -> String {
        guard let sessionError = error as? DeviceSessionError else {
            return "Glasses session failed: \(error)"
        }
        switch sessionError {
        case .noEligibleDevice:
            return "No glasses connected. Put them on, then open the Meta AI app and check they show as Connected."
        case .datAppOnTheGlassesUpdateRequired:
            return "Your glasses need a firmware update. Update them in the Meta AI app."
        case .batteryCritical:
            return "Glasses battery is too low. Charge them."
        case .thermalCritical, .thermalEmergency, .peakPowerShutdown:
            return "Glasses are too hot. Let them cool down."
        case .dwaUnavailable:
            return "The glasses are busy with another app. Close it and try again."
        case .sessionAlreadyExists, .sessionAlreadyStopped, .sessionIdle:
            return "Glasses session is in a stale state. Restart the app."
        default:
            return sessionError.errorDescription ?? "Glasses session failed."
        }
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
