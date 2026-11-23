import AVFoundation
import LautliKit
import Observation

/// Runs the dictation session in the app: applies keyboard commands to `DictationSession`, performs its
/// effects (capture, upload) and publishes each phase to the keyboard through the shared container.
@MainActor @Observable
final class DictationController {
    enum Problem: Equatable {
        case microphoneDenied
        case microphoneUnavailable
        case sharedContainerUnavailable
    }

    private(set) var phase: DictationPhase = .inactive
    private(set) var problem: Problem?
    var serverAddress: String {
        didSet { UserDefaults.standard.set(serverAddress, forKey: Self.serverAddressKey) }
    }

    @ObservationIgnored private var session = DictationSession()
    @ObservationIgnored private let capture = AudioCapture()
    @ObservationIgnored private let store = SharedDictationStore.appGroup()
    @ObservationIgnored private var lastAppliedCommand: IssuedCommand?
    @ObservationIgnored private var commandObserver: DarwinSignalObserver?
    @ObservationIgnored private var heartbeat: Timer?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?

    private static let serverAddressKey = "transcriptionServerAddress"

    init() {
        serverAddress = UserDefaults.standard.string(forKey: Self.serverAddressKey) ?? ""
        if store == nil { problem = .sharedContainerUnavailable }
        commandObserver = DarwinSignalObserver(.commandIssued) { [weak self] in self?.applyPendingCommand() }
        publish()
    }

    /// The keyboard wrote a start command and opened `lautli://dictate`.
    func openedFromKeyboard() async {
        await activate()
        applyPendingCommand()
    }

    func activate() async {
        guard phase == .inactive else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            problem = .microphoneDenied
            return
        }
        do {
            try capture.start()
        } catch {
            problem = .microphoneUnavailable
            return
        }
        if problem != .sharedContainerUnavailable { problem = nil }
        observeInterruptions()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(.tick(at: .now)) }
        }
        handle(.sessionActivated(at: .now))
    }

    func endSession() {
        handle(.sessionEndedByUser)
    }

    /// The in-app test button, for trying dictation without the keyboard.
    func toggleRecording() {
        guard let command = MicrophoneButton(snapshot: SessionSnapshot(phase: phase, heartbeatAt: .now), now: .now)
            .command(for: DictationRequestID())
        else { return }
        handle(.command(command, at: .now))
    }

    func dismissResult() {
        switch phase {
        case .transcribed(let id, _), .failed(let id, _): handle(.command(.acknowledge(id), at: .now))
        default: return
        }
    }

    private func applyPendingCommand() {
        guard let store else { return }
        let issued: IssuedCommand?
        do {
            issued = try store.readCommand()
        } catch {
            problem = .sharedContainerUnavailable
            return
        }
        // The same file is seen again when the URL open and a signal race; apply each command once.
        guard let issued, issued.isFresh(at: .now), issued != lastAppliedCommand else { return }
        lastAppliedCommand = issued
        handle(.command(issued.command, at: .now))
    }

    private func handle(_ event: DictationEvent) {
        let effects = session.handle(event)
        let changed = phase != session.phase
        phase = session.phase
        effects.forEach(perform)
        publish(signal: changed)
    }

    private func perform(_ effect: DictationEffect) {
        switch effect {
        case .beginCapture(let id):
            // On failure no clip exists, so finishing it reports `recordingFailed` to the keyboard.
            try? capture.beginClip(at: FileManager.default.temporaryDirectory.appending(path: "\(id).m4a"))
        case .finishCaptureAndTranscribe(let id):
            let clip = capture.finishClip()
            Task {
                let result = await transcribe(clip, id: id)
                handle(.transcriptionFinished(id, result, at: .now))
            }
        case .discardCapture:
            capture.discardClip()
        case .endAudioSession:
            capture.stop()
            heartbeat?.invalidate()
            heartbeat = nil
            interruptionObserver.map(NotificationCenter.default.removeObserver)
            interruptionObserver = nil
        }
    }

    private func transcribe(_ clip: URL?, id: DictationRequestID) async -> Result<String, DictationFailure> {
        guard let clip else { return .failure(.recordingFailed) }
        defer { try? FileManager.default.removeItem(at: clip) }
        guard let server = TranscriptionAPI.serverURL(from: serverAddress) else { return .failure(.noServerConfigured) }
        guard let audio = try? Data(contentsOf: clip) else { return .failure(.recordingFailed) }
        do {
            let (body, response) = try await URLSession.shared.data(for: TranscriptionAPI.request(serverURL: server, clip: audio, requestID: id))
            guard let http = response as? HTTPURLResponse else { return .failure(.server) }
            return TranscriptionAPI.transcript(statusCode: http.statusCode, body: body)
        } catch {
            return .failure(.network)
        }
    }

    private func publish(signal: Bool = true) {
        guard let store else { return }
        do {
            try store.writeSnapshot(SessionSnapshot(phase: phase, heartbeatAt: .now))
        } catch {
            problem = .sharedContainerUnavailable
            return
        }
        // Heartbeat-only writes stay silent so the keyboard is not woken every second.
        if signal { DarwinSignalCenter.post(.snapshotChanged) }
    }

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            guard began else { return }
            MainActor.assumeIsolated { self?.handle(.audioInterrupted) }
        }
    }
}
