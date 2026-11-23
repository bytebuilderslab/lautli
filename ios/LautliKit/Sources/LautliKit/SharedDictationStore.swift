import Foundation

/// Files in the App Group container that the app and the keyboard exchange. Each file has one writer
/// (snapshot: app, command: keyboard), so concurrent writes never race on the same file.
public struct SharedDictationStore: Sendable {
    public static let appGroupIdentifier = "group.io.github.ameetmadan.lautli"

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Nil when the App Group is missing from the entitlements, or the keyboard runs without Full Access.
    public static func appGroup() -> SharedDictationStore? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
            .map(SharedDictationStore.init(directory:))
    }

    public func writeSnapshot(_ snapshot: SessionSnapshot) throws {
        try write(snapshot, to: "dictation-snapshot.json")
    }

    public func readSnapshot() throws -> SessionSnapshot? {
        try read(SessionSnapshot.self, from: "dictation-snapshot.json")
    }

    public func writeCommand(_ command: IssuedCommand) throws {
        try write(command, to: "dictation-command.json")
    }

    public func readCommand() throws -> IssuedCommand? {
        try read(IssuedCommand.self, from: "dictation-command.json")
    }

    private func write(_ value: some Encodable, to name: String) throws {
        let data = try JSONEncoder().encode(value)
        // Atomic so the other process never reads half a file. Transcripts are readable after first unlock
        // because the keyboard is used while the phone is unlocked, never before the first unlock.
        try data.write(to: directory.appending(path: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func read<Value: Decodable>(_ type: Value.Type, from name: String) throws -> Value? {
        let url = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: url))
        } catch is DecodingError {
            // A file from another contract version: the caller treats it like no file at all.
            return nil
        }
    }
}
