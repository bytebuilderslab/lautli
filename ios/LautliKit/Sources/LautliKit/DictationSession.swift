import Foundation

public enum DictationEvent: Equatable, Sendable {
    /// The app started its audio session (opened from the keyboard, or the user tapped Start in the app).
    case sessionActivated(at: Date)
    case command(DictationCommand, at: Date)
    case transcriptionFinished(DictationRequestID, Result<String, DictationFailure>, at: Date)
    /// A phone call, Siri or another app took the microphone.
    case audioInterrupted
    case sessionEndedByUser
    /// Sent once a second while the session runs; enforces the recording limit and the idle timeout.
    case tick(at: Date)
}

public enum DictationEffect: Equatable, Sendable {
    case beginCapture(DictationRequestID)
    case finishCaptureAndTranscribe(DictationRequestID)
    case discardCapture
    case endAudioSession
}

/// The dictation lifecycle as the app runs it. Pure: the app performs the returned effects.
public struct DictationSession: Equatable, Sendable {
    public struct Limits: Equatable, Sendable {
        /// How long the microphone stays held, waiting for the next dictation, after the last one.
        public var idleTimeout: TimeInterval
        public var maximumRecording: TimeInterval

        public init(idleTimeout: TimeInterval, maximumRecording: TimeInterval) {
            self.idleTimeout = idleTimeout
            self.maximumRecording = maximumRecording
        }

        // shortcut: fixed values until Phase 2 measures battery use and server cost; then make idle configurable.
        public static let standard = Limits(idleTimeout: 5 * 60, maximumRecording: 5 * 60)
    }

    public private(set) var phase: DictationPhase = .inactive
    private var idleDeadline: Date?
    private let limits: Limits

    public init(limits: Limits = .standard) {
        self.limits = limits
    }

    public mutating func handle(_ event: DictationEvent) -> [DictationEffect] {
        switch (phase, event) {
        case (.inactive, .sessionActivated(let now)):
            becomeIdle(.ready, at: now)
            return []

        case (_, .sessionEndedByUser), (_, .audioInterrupted):
            return end()

        case (.ready, .command(.start(let id), let now)),
             (.transcribed, .command(.start(let id), let now)),
             (.failed, .command(.start(let id), let now)):
            phase = .recording(id, startedAt: now)
            idleDeadline = nil
            return [.beginCapture(id)]

        case (.recording(let current, _), .command(.stop(let id), _)) where id == current:
            phase = .transcribing(id)
            return [.finishCaptureAndTranscribe(id)]

        case (.recording(let current, let startedAt), .tick(let now)):
            guard now.timeIntervalSince(startedAt) >= limits.maximumRecording else { return [] }
            phase = .transcribing(current)
            return [.finishCaptureAndTranscribe(current)]

        case (.recording(let current, _), .command(.cancel(let id), let now)) where id == current:
            becomeIdle(.ready, at: now)
            return [.discardCapture]

        // Cancelling during upload drops the request; its late result no longer matches the phase.
        case (.transcribing(let current), .command(.cancel(let id), let now)) where id == current:
            becomeIdle(.ready, at: now)
            return []

        case (.transcribing(let current), .transcriptionFinished(let id, let result, let now)) where id == current:
            becomeIdle(Self.phase(for: id, result), at: now)
            return []

        case (.transcribed(let current, _), .command(.acknowledge(let id), let now)) where id == current,
             (.failed(let current, _), .command(.acknowledge(let id), let now)) where id == current:
            becomeIdle(.ready, at: now)
            return []

        case (.ready, .tick(let now)), (.transcribed, .tick(let now)), (.failed, .tick(let now)):
            guard let idleDeadline, now >= idleDeadline else { return [] }
            return end()

        default:
            return []
        }
    }

    private mutating func becomeIdle(_ next: DictationPhase, at now: Date) {
        phase = next
        idleDeadline = now.addingTimeInterval(limits.idleTimeout)
    }

    private mutating func end() -> [DictationEffect] {
        let wasRecording = if case .recording = phase { true } else { false }
        let wasActive = phase != .inactive
        phase = .inactive
        idleDeadline = nil
        guard wasActive else { return [] }
        return wasRecording ? [.discardCapture, .endAudioSession] : [.endAudioSession]
    }

    private static func phase(for id: DictationRequestID, _ result: Result<String, DictationFailure>) -> DictationPhase {
        switch result {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .failed(id, .emptyTranscript) : .transcribed(id, text: trimmed)
        case .failure(let failure):
            return .failed(id, failure)
        }
    }
}
