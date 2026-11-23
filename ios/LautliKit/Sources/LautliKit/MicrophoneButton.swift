import Foundation

/// What the keyboard's microphone button means right now, derived from the app's last snapshot.
public enum MicrophoneButton: Equatable, Sendable {
    /// The app is not running a session: tapping it opens the app, which starts recording at once.
    case openAppToRecord
    case record
    case stop(DictationRequestID)
    case busy

    public init(snapshot: SessionSnapshot?, now: Date) {
        guard let snapshot, snapshot.isAppListening(at: now) else {
            self = .openAppToRecord
            return
        }
        switch snapshot.phase {
        case .inactive: self = .openAppToRecord
        case .ready, .transcribed, .failed: self = .record
        case .recording(let id, _): self = .stop(id)
        case .transcribing: self = .busy
        }
    }

    /// The command to issue for a tap. `newRequest` is only used when a recording would start.
    public func command(for newRequest: DictationRequestID) -> DictationCommand? {
        switch self {
        case .openAppToRecord, .record: .start(newRequest)
        case .stop(let id): .stop(id)
        case .busy: nil
        }
    }
}
