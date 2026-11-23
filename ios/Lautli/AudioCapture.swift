import AVFoundation

/// Holds the microphone for a dictation session and writes clips on request.
///
/// The input tap runs for the whole session, not only while recording: a running input keeps the app alive in
/// the background (`UIBackgroundModes: audio`), so the keyboard can start the next dictation without opening
/// the app again. Samples outside a clip are dropped as they arrive. iOS shows the orange microphone
/// indicator the whole time, which is the honest signal for this.
nonisolated final class AudioCapture: @unchecked Sendable {
    enum CaptureError: Error {
        case noInput
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var clip: AVAudioFile?
    private var clipFailed = false

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // Mixing so music or a podcast in another app keeps playing while the microphone is held.
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw CaptureError.noInput }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        discardClip()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func beginClip(at url: URL) throws {
        let format = engine.inputNode.outputFormat(forBus: 0)
        // AAC at 32 kbit/s keeps a 30-second clip near the ~100 KB the server API is sized for.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 32_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        lock.withLock {
            clip = file
            clipFailed = false
        }
    }

    /// Closes the clip and returns its file, or nil when writing failed part-way (the clip would be truncated).
    func finishClip() -> URL? {
        // Releasing the AVAudioFile is what finalizes the container, so it happens before the URL is used.
        let (url, failed) = lock.withLock {
            defer { clip = nil }
            return (clip?.url, clipFailed)
        }
        guard let url else { return nil }
        guard !failed else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    func discardClip() {
        let url = lock.withLock {
            defer { clip = nil }
            return clip?.url
        }
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let clip, !clipFailed else { return }
            do {
                try clip.write(from: buffer)
            } catch {
                clipFailed = true
            }
        }
    }
}
