import XCTest
@testable import LautliKit

final class ExchangeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testMicrophoneOpensTheAppWhenNoSnapshotExists() {
        XCTAssertEqual(MicrophoneButton(snapshot: nil, now: now), .openAppToRecord)
    }

    func testMicrophoneOpensTheAppWhenTheHeartbeatIsStale() {
        let snapshot = SessionSnapshot(phase: .ready, heartbeatAt: now.addingTimeInterval(-6))
        XCTAssertEqual(MicrophoneButton(snapshot: snapshot, now: now), .openAppToRecord)
    }

    func testMicrophoneRecordsDirectlyWhileTheAppListens() {
        let snapshot = SessionSnapshot(phase: .ready, heartbeatAt: now.addingTimeInterval(-1))
        let button = MicrophoneButton(snapshot: snapshot, now: now)
        let id = DictationRequestID()

        XCTAssertEqual(button, .record)
        XCTAssertEqual(button.command(for: id), .start(id))
    }

    func testMicrophoneStopsTheCurrentRecording() {
        let id = DictationRequestID()
        let snapshot = SessionSnapshot(phase: .recording(id, startedAt: now), heartbeatAt: now)
        let button = MicrophoneButton(snapshot: snapshot, now: now)

        XCTAssertEqual(button.command(for: DictationRequestID()), .stop(id))
    }

    func testMicrophoneDoesNothingWhileTranscribing() {
        let snapshot = SessionSnapshot(phase: .transcribing(DictationRequestID()), heartbeatAt: now)
        XCTAssertNil(MicrophoneButton(snapshot: snapshot, now: now).command(for: DictationRequestID()))
    }

    func testCommandsExpire() {
        let command = IssuedCommand(.start(DictationRequestID()), issuedAt: now)
        XCTAssertTrue(command.isFresh(at: now.addingTimeInterval(30)))
        XCTAssertFalse(command.isFresh(at: now.addingTimeInterval(31)))
    }

    func testStoreRoundTripsBothFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedDictationStore(directory: directory)
        let id = DictationRequestID()

        XCTAssertNil(try store.readSnapshot())
        let snapshot = SessionSnapshot(phase: .transcribed(id, text: "Hallo"), heartbeatAt: now)
        try store.writeSnapshot(snapshot)
        try store.writeCommand(IssuedCommand(.acknowledge(id), issuedAt: now))

        XCTAssertEqual(try store.readSnapshot(), snapshot)
        XCTAssertEqual(try store.readCommand()?.command, .acknowledge(id))
    }

    func testStoreTreatsAnUnreadableFileAsMissing() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{\"version\":2}".utf8).write(to: directory.appending(path: "dictation-snapshot.json"))

        XCTAssertNil(try SharedDictationStore(directory: directory).readSnapshot())
    }

    func testTranscriptIsReadFromTheEnvelope() {
        let body = Data(#"{"data":{"text":"Hallo Sarah"},"error":null,"meta":{"timestamp":"2026-11-23T10:00:00Z"}}"#.utf8)
        XCTAssertEqual(TranscriptionAPI.transcript(statusCode: 200, body: body), .success("Hallo Sarah"))
    }

    func testErrorEnvelopeAndBadStatusAreServerFailures() {
        let error = Data(#"{"data":null,"error":{"code":"clip_too_long"},"meta":{}}"#.utf8)
        XCTAssertEqual(TranscriptionAPI.transcript(statusCode: 413, body: error), .failure(.server))
        XCTAssertEqual(TranscriptionAPI.transcript(statusCode: 200, body: error), .failure(.server))
        XCTAssertEqual(TranscriptionAPI.transcript(statusCode: 200, body: Data("<html>".utf8)), .failure(.server))
    }

    func testRequestTargetsTheVersionedEndpoint() throws {
        let server = try XCTUnwrap(TranscriptionAPI.serverURL(from: " http://192.168.1.20:8765 "))
        let id = DictationRequestID()
        let request = TranscriptionAPI.request(serverURL: server, clip: Data([1, 2]), requestID: id)

        XCTAssertEqual(request.url?.absoluteString, "http://192.168.1.20:8765/api/v1/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Request-ID"), id.description)
    }

    func testServerURLRejectsNonHTTPInput() {
        XCTAssertNil(TranscriptionAPI.serverURL(from: ""))
        XCTAssertNil(TranscriptionAPI.serverURL(from: "lautli.example"))
        XCTAssertNil(TranscriptionAPI.serverURL(from: "ftp://lautli.example"))
    }
}
