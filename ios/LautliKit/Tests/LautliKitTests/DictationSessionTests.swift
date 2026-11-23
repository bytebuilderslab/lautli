import XCTest
@testable import LautliKit

final class DictationSessionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private let limits = DictationSession.Limits(idleTimeout: 60, maximumRecording: 30)

    private func activeSession() -> DictationSession {
        var session = DictationSession(limits: limits)
        XCTAssertEqual(session.handle(.sessionActivated(at: start)), [])
        return session
    }

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testFullDictationFromStartToAcknowledgedResult() {
        var session = activeSession()
        let id = DictationRequestID()

        XCTAssertEqual(session.handle(.command(.start(id), at: at(1))), [.beginCapture(id)])
        XCTAssertEqual(session.handle(.command(.stop(id), at: at(5))), [.finishCaptureAndTranscribe(id)])
        XCTAssertEqual(session.phase, .transcribing(id))

        XCTAssertEqual(session.handle(.transcriptionFinished(id, .success("  Hallo Sarah. \n"), at: at(6))), [])
        XCTAssertEqual(session.phase, .transcribed(id, text: "Hallo Sarah."))

        XCTAssertEqual(session.handle(.command(.acknowledge(id), at: at(7))), [])
        XCTAssertEqual(session.phase, .ready)
    }

    func testCommandsBeforeTheAudioSessionRunsAreIgnored() {
        var session = DictationSession(limits: limits)
        XCTAssertEqual(session.handle(.command(.start(DictationRequestID()), at: start)), [])
        XCTAssertEqual(session.phase, .inactive)
    }

    func testRepeatedStartWhileRecordingDoesNotRestartCapture() {
        var session = activeSession()
        let id = DictationRequestID()
        _ = session.handle(.command(.start(id), at: at(1)))

        XCTAssertEqual(session.handle(.command(.start(id), at: at(2))), [])
        XCTAssertEqual(session.handle(.command(.start(DictationRequestID()), at: at(2))), [])
        XCTAssertEqual(session.phase, .recording(id, startedAt: at(1)))
    }

    func testStopForAnotherRequestIsIgnored() {
        var session = activeSession()
        let id = DictationRequestID()
        _ = session.handle(.command(.start(id), at: at(1)))

        XCTAssertEqual(session.handle(.command(.stop(DictationRequestID()), at: at(2))), [])
        XCTAssertEqual(session.phase, .recording(id, startedAt: at(1)))
    }

    func testCancelWhileRecordingDiscardsAudio() {
        var session = activeSession()
        let id = DictationRequestID()
        _ = session.handle(.command(.start(id), at: at(1)))

        XCTAssertEqual(session.handle(.command(.cancel(id), at: at(2))), [.discardCapture])
        XCTAssertEqual(session.phase, .ready)
    }

    func testResultArrivingAfterCancelIsDropped() {
        var session = activeSession()
        let id = DictationRequestID()
        _ = session.handle(.command(.start(id), at: at(1)))
        _ = session.handle(.command(.stop(id), at: at(2)))
        _ = session.handle(.command(.cancel(id), at: at(3)))

        XCTAssertEqual(session.handle(.transcriptionFinished(id, .success("late"), at: at(4))), [])
        XCTAssertEqual(session.phase, .ready)
    }

    func testResultForAnEarlierRequestCannotReplaceTheCurrentOne() {
        var session = activeSession()
        let first = DictationRequestID()
        let second = DictationRequestID()
        _ = session.handle(.command(.start(first), at: at(1)))
        _ = session.handle(.command(.stop(first), at: at(2)))
        _ = session.handle(.command(.cancel(first), at: at(3)))
        _ = session.handle(.command(.start(second), at: at(4)))
        _ = session.handle(.command(.stop(second), at: at(5)))

        _ = session.handle(.transcriptionFinished(first, .success("old"), at: at(6)))
        XCTAssertEqual(session.phase, .transcribing(second))
    }

    func testBlankTranscriptBecomesAFailureInsteadOfEmptyText() {
        var session = activeSession()
        let id = DictationRequestID()
        _ = session.handle(.command(.start(id), at: at(1)))
        _ = session.handle(.command(.stop(id), at: at(2)))

        _ = session.handle(.transcriptionFinished(id, .success(" \n"), at: at(3)))
        XCTAssertEqual(session.phase, .failed(id, .emptyTranscript))
    }

    func testServerFailureIsReportedAndCanBeAcknowledged() {
        var session = activeSession()
        let id = DictationRequestID()
        _ = session.handle(.command(.start(id), at: at(1)))
        _ = session.handle(.command(.stop(id), at: at(2)))
        _ = session.handle(.transcriptionFinished(id, .failure(.network), at: at(3)))
        XCTAssertEqual(session.phase, .failed(id, .network))

        _ = session.handle(.command(.acknowledge(id), at: at(4)))
        XCTAssertEqual(session.phase, .ready)
    }

    func testRecordingStopsItselfAtTheLimit() {
        var session = activeSession()
        let id = DictationRequestID()
        _ = session.handle(.command(.start(id), at: at(0)))

        XCTAssertEqual(session.handle(.tick(at: at(29))), [])
        XCTAssertEqual(session.handle(.tick(at: at(30))), [.finishCaptureAndTranscribe(id)])
        XCTAssertEqual(session.phase, .transcribing(id))
    }

    func testIdleSessionReleasesTheMicrophoneAfterTheTimeout() {
        var session = activeSession()

        XCTAssertEqual(session.handle(.tick(at: at(59))), [])
        XCTAssertEqual(session.handle(.tick(at: at(60))), [.endAudioSession])
        XCTAssertEqual(session.phase, .inactive)
    }

    func testUnacknowledgedResultExpiresWithTheSession() {
        var session = activeSession()
        let id = DictationRequestID()
        _ = session.handle(.command(.start(id), at: at(1)))
        _ = session.handle(.command(.stop(id), at: at(2)))
        _ = session.handle(.transcriptionFinished(id, .success("Hallo"), at: at(3)))

        XCTAssertEqual(session.handle(.tick(at: at(63))), [.endAudioSession])
        XCTAssertEqual(session.phase, .inactive)
    }

    func testDictatingKeepsTheSessionAliveBeyondTheFirstTimeout() {
        var session = activeSession()
        let id = DictationRequestID()
        _ = session.handle(.command(.start(id), at: at(50)))

        XCTAssertEqual(session.handle(.tick(at: at(61))), [])
        _ = session.handle(.command(.stop(id), at: at(65)))
        _ = session.handle(.transcriptionFinished(id, .success("Hallo"), at: at(66)))
        _ = session.handle(.command(.acknowledge(id), at: at(70)))

        XCTAssertEqual(session.handle(.tick(at: at(129))), [])
        XCTAssertEqual(session.handle(.tick(at: at(130))), [.endAudioSession])
    }

    func testInterruptionWhileRecordingDiscardsAudioAndEndsTheSession() {
        var session = activeSession()
        _ = session.handle(.command(.start(DictationRequestID()), at: at(1)))

        XCTAssertEqual(session.handle(.audioInterrupted), [.discardCapture, .endAudioSession])
        XCTAssertEqual(session.phase, .inactive)
    }

    func testEndingAnInactiveSessionDoesNothing() {
        var session = DictationSession(limits: limits)
        XCTAssertEqual(session.handle(.sessionEndedByUser), [])
    }

    func testNewDictationReplacesAnUninsertedResult() {
        var session = activeSession()
        let first = DictationRequestID()
        let second = DictationRequestID()
        _ = session.handle(.command(.start(first), at: at(1)))
        _ = session.handle(.command(.stop(first), at: at(2)))
        _ = session.handle(.transcriptionFinished(first, .success("Hallo"), at: at(3)))

        XCTAssertEqual(session.handle(.command(.start(second), at: at(4))), [.beginCapture(second)])
    }
}
