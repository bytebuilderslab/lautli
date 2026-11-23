import LautliKit
import SwiftUI

struct ContentView: View {
    @Bindable var controller: DictationController
    /// Set when the keyboard opened the app, so the screen says how to get back to the text field.
    @State private var openedFromKeyboard = false

    var body: some View {
        NavigationStack {
            Form {
                if openedFromKeyboard, case .recording = controller.phase {
                    Section {
                        Label("Recording. Swipe back to your app, or tap ◀ in the top-left corner.", systemImage: "arrow.uturn.backward")
                            .font(.headline)
                    }
                }
                sessionSection
                if let problem = controller.problem {
                    Section { Label(problem.message, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                serverSection
                setupSection
            }
            .navigationTitle("lautli")
        }
        .onOpenURL { url in
            guard url.scheme == "lautli", url.host() == "dictate" else { return }
            openedFromKeyboard = true
            Task { await controller.openedFromKeyboard() }
        }
        .onChange(of: controller.phase) { _, phase in
            if case .recording = phase { return }
            openedFromKeyboard = false
        }
    }

    private var sessionSection: some View {
        Section {
            LabeledContent("Status", value: controller.phase.label)
            switch controller.phase {
            case .inactive:
                Button("Start dictation session") { Task { await controller.activate() } }
            case .ready, .recording, .transcribing:
                Button(controller.phase.isRecording ? "Stop recording" : "Record test dictation") { controller.toggleRecording() }
                    .disabled(controller.phase.isTranscribing)
                Button("End session", role: .destructive) { controller.endSession() }
            case .transcribed(_, let text):
                Text(text).textSelection(.enabled)
                Button("Copy") {
                    UIPasteboard.general.string = text
                    controller.dismissResult()
                }
                Button("Discard", role: .destructive) { controller.dismissResult() }
            case .failed(_, let failure):
                Text(failure.message).foregroundStyle(.red)
                Button("OK") { controller.dismissResult() }
            }
        } header: {
            Text("Dictation")
        } footer: {
            Text("While a session runs, lautli keeps the microphone open so the keyboard can start dictating without opening the app. It ends after 5 minutes without dictation.")
        }
    }

    private var serverSection: some View {
        Section {
            TextField("https://lautli.example", text: $controller.serverAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !controller.serverAddress.isEmpty, TranscriptionAPI.serverURL(from: controller.serverAddress) == nil {
                Text("Enter an http:// or https:// address.").foregroundStyle(.red)
            }
        } header: {
            Text("Transcription server")
        } footer: {
            Text("Each dictation is sent to this server for transcription. The server does not keep audio or text.")
        }
    }

    private var setupSection: some View {
        Section("Keyboard setup") {
            Text("1. Settings → General → Keyboard → Keyboards → Add New Keyboard → lautli")
            Text("2. Tap lautli and turn on Allow Full Access, which the keyboard needs to talk to this app.")
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
    }
}

private extension DictationPhase {
    var label: String {
        switch self {
        case .inactive: "Not running"
        case .ready: "Ready"
        case .recording: "Recording"
        case .transcribing: "Transcribing"
        case .transcribed: "Done"
        case .failed: "Failed"
        }
    }

    var isRecording: Bool { if case .recording = self { true } else { false } }
    var isTranscribing: Bool { if case .transcribing = self { true } else { false } }
}

private extension DictationController.Problem {
    var message: String {
        switch self {
        case .microphoneDenied: "lautli needs microphone access. Turn it on in Settings → lautli."
        case .microphoneUnavailable: "The microphone is unavailable. End a call or recording in another app and try again."
        case .sharedContainerUnavailable: "lautli cannot share dictations with its keyboard. Reinstall the app."
        }
    }
}
