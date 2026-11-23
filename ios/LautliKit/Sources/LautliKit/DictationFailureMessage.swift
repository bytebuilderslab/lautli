public extension DictationFailure {
    /// Shown by both the app and the keyboard.
    var message: String {
        switch self {
        case .noServerConfigured: "Add a transcription server address in lautli."
        case .network: "Could not reach the transcription server."
        case .server: "The transcription server could not transcribe this dictation."
        case .emptyTranscript: "No speech was recognised."
        case .recordingFailed: "The recording failed."
        }
    }
}
