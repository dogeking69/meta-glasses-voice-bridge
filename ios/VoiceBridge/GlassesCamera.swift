import Foundation

#if canImport(MWDATCamera)
import MWDATCamera
import MWDATCore
#endif

/// Takes a single photo through the camera in the glasses.
///
/// This is the one part of the Meta toolkit that gives real sensor access. The
/// microphone is not exposed at all (see `GlassesManager`), and `DeviceState`
/// carries nothing but a thermal level, so a photo is the only thing the
/// glasses can actually tell you about the world in front of you.
///
/// The camera hardware is claimed for the length of one capture and released
/// straight afterwards. Holding it open keeps the glasses warm and stops other
/// apps using it, and a still frame is all the listener needs.
@MainActor
final class GlassesCamera: ObservableObject {
    @Published private(set) var isCapturing = false

    /// How long to wait for the stream to come up, and then for the photo
    /// itself. The glasses take a moment to wake the camera.
    private let startTimeout: Duration = .seconds(12)
    private let photoTimeout: Duration = .seconds(20)

    enum CameraError: LocalizedError {
        case toolkitMissing
        case noSession
        case permissionDenied
        case cameraUnavailable
        case timedOut(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .toolkitMissing:
                return "The camera needs the Meta toolkit. See the README."
            case .noSession:
                return "No glasses session. Put the glasses on and check the Glasses row."
            case .permissionDenied:
                return "Camera access was refused. Approve it in the Meta AI app."
            case .cameraUnavailable:
                return "These glasses do not offer a camera to this app."
            case .timedOut(let stage):
                return "The glasses did not \(stage) in time. Try again."
            case .failed(let detail):
                return detail
            }
        }
    }

    #if canImport(MWDATCamera)

    /// Capture one photo as JPEG data. Throws rather than returning nil so the
    /// reason can be spoken back to the wearer.
    func capture(session: DeviceSession) async throws -> Data {
        guard !isCapturing else { throw CameraError.failed("A photo is already being taken.") }
        isCapturing = true
        defer { isCapturing = false }

        let status = try await Wearables.shared.requestPermission(.camera)
        guard status == .granted else { throw CameraError.permissionDenied }

        guard let camera = try session.addCamera() else { throw CameraError.cameraUnavailable }
        defer { camera.stop() }

        let stream = camera.stream
        let streaming = OneShot<Void>()
        let photo = OneShot<Data>()

        // Errors can arrive before either of the other two, so they complete
        // both promises — whichever one is being waited on gives up.
        let errorToken = stream.errorPublisher.listen { streamError in
            let failure = CameraError.failed(Self.explain(streamError))
            streaming.complete(.failure(failure))
            photo.complete(.failure(failure))
        }
        let stateToken = stream.statePublisher.listen { state in
            if state == .streaming { streaming.complete(.success(())) }
        }
        let photoToken = stream.photoDataPublisher.listen { data in
            photo.complete(.success(data.data))
        }
        defer {
            Task {
                await errorToken.cancel()
                await stateToken.cancel()
                await photoToken.cancel()
            }
        }

        stream.start()
        try await streaming.value(within: startTimeout,
                                  orThrow: CameraError.timedOut("wake the camera"))

        guard stream.capturePhoto(format: .jpeg) else {
            throw CameraError.failed("The glasses refused to take a photo.")
        }
        let data = try await photo.value(within: photoTimeout,
                                         orThrow: CameraError.timedOut("send the photo"))
        stream.stop()
        return data
    }

    /// `StreamError` says what went wrong but not what to do about it.
    ///
    /// Nonisolated because the toolkit calls its error listener from its own
    /// thread, not the main actor.
    private nonisolated static func explain(_ error: StreamError) -> String {
        switch error {
        case .permissionDenied:
            return "Camera access was refused. Approve it in the Meta AI app."
        case .hingesClosed:
            return "The glasses are folded up or off your face."
        case .deviceNotConnected, .deviceNotFound:
            return "The glasses dropped their connection."
        case .batteryCritical:
            return "The glasses battery is too low for the camera."
        case .thermalCritical, .thermalEmergency, .peakPowerShutdown:
            return "The glasses are too hot to use the camera. Let them cool down."
        case .photoCaptureFailed:
            return "The photo did not come out. Try again."
        case .timeout:
            return "The glasses camera timed out."
        default:
            return error.errorDescription ?? "The glasses camera failed."
        }
    }

    #endif
}

/// A result that can only be delivered once.
///
/// The toolkit calls its listeners from its own threads and may call them more
/// than once — a second `.streaming` state, an error after a photo. Resuming a
/// continuation twice is a crash, so every completion goes through here.
private final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var waiter: CheckedContinuation<Value, Error>?

    func complete(_ outcome: Result<Value, Error>) {
        lock.lock()
        guard result == nil else { return lock.unlock() }
        result = outcome
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(with: outcome)
    }

    /// Wait for the value, giving up after `timeout`.
    func value(within timeout: Duration, orThrow timeoutError: Error) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await self.value() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw timeoutError
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }
}
