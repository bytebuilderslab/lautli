import Foundation

/// The app and the keyboard extension are separate processes that can be on different builds after an update.
/// Each side ignores a file written under another version instead of guessing at its shape.
public let dictationContractVersion = 1

public struct DictationRequestID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

/// What the keyboard asks the app to do. The keyboard is the only writer of commands.
public enum DictationCommand: Codable, Equatable, Sendable {
    case start(DictationRequestID)
    case stop(DictationRequestID)
    case cancel(DictationRequestID)
    /// The keyboard inserted or discarded the result, so the app can drop it.
    case acknowledge(DictationRequestID)
}

public struct IssuedCommand: Codable, Equatable, Sendable {
    public let version: Int
    public let command: DictationCommand
    public let issuedAt: Date

    public init(_ command: DictationCommand, issuedAt: Date) {
        self.version = dictationContractVersion
        self.command = command
        self.issuedAt = issuedAt
    }

    /// A command read from disk long after it was written (the app was killed, the user wandered off)
    /// must not start a recording the user no longer expects.
    public func isFresh(at now: Date) -> Bool {
        version == dictationContractVersion && now.timeIntervalSince(issuedAt) <= Self.lifetime
    }

    static let lifetime: TimeInterval = 30
}

public enum DictationFailure: String, Codable, Equatable, Sendable, Error {
    case noServerConfigured
    case network
    case server
    case emptyTranscript
    case recordingFailed
}

public enum DictationPhase: Codable, Equatable, Sendable {
    /// No audio session. The keyboard has to open the app before anyone can dictate.
    case inactive
    /// The microphone is held and the app can start recording when the keyboard asks.
    case ready
    case recording(DictationRequestID, startedAt: Date)
    case transcribing(DictationRequestID)
    case transcribed(DictationRequestID, text: String)
    case failed(DictationRequestID, DictationFailure)
}

/// What the app publishes for the keyboard. The app is the only writer of snapshots.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let phase: DictationPhase
    public let heartbeatAt: Date

    public init(phase: DictationPhase, heartbeatAt: Date) {
        self.version = dictationContractVersion
        self.phase = phase
        self.heartbeatAt = heartbeatAt
    }

    /// The app refreshes `heartbeatAt` every second while its audio session runs. A killed app leaves
    /// its last snapshot behind, so an old heartbeat means nobody is listening for commands.
    public func isAppListening(at now: Date) -> Bool {
        version == dictationContractVersion
            && phase != .inactive
            && now.timeIntervalSince(heartbeatAt) <= Self.heartbeatTolerance
    }

    static let heartbeatTolerance: TimeInterval = 5
}

/// Names of the Darwin notifications the two processes use to wake each other. They carry no payload;
/// the receiver reads the matching file from the shared container.
public enum DictationSignal: String, Sendable {
    case commandIssued = "io.github.ameetmadan.lautli.dictation.command"
    case snapshotChanged = "io.github.ameetmadan.lautli.dictation.snapshot"
}
