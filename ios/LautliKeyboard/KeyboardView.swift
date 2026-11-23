import LautliKit
import SwiftUI

struct KeyboardView: View {
    let model: KeyboardModel
    let showsNextKeyboard: Bool

    var body: some View {
        VStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                dictationArea(now: context.date)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            keyRow
        }
        .padding(8)
    }

    @ViewBuilder
    private func dictationArea(now: Date) -> some View {
        if let notice = model.notice {
            Text(notice).font(.callout).multilineTextAlignment(.center)
        } else if case .transcribed(let id, let text)? = model.pendingResult {
            VStack(spacing: 8) {
                ScrollView { Text(text).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("Discard", role: .destructive) { model.acknowledge(id) }
                    Spacer()
                    Button("Insert text") { model.insert(text, for: id) }.buttonStyle(.borderedProminent)
                }
            }
        } else if case .failed(let id, let failure)? = model.pendingResult {
            VStack(spacing: 8) {
                Text(failure.message).multilineTextAlignment(.center)
                Button("OK") { model.acknowledge(id) }
            }
        } else {
            microphone(model.microphoneButton(at: now), now: now)
        }
    }

    @ViewBuilder
    private func microphone(_ button: MicrophoneButton, now: Date) -> some View {
        VStack(spacing: 6) {
            Button(action: model.tapMicrophone) {
                Image(systemName: button.symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 72, height: 72)
                    .background(button.isStop ? Color.red : Color.accentColor, in: Circle())
                    .foregroundStyle(.white)
            }
            .disabled(button == .busy)
            .accessibilityLabel(button.accessibilityLabel)
            Text(caption(for: button, now: now)).font(.caption).foregroundStyle(.secondary)
            if case .stop(let id) = button {
                Button("Cancel") { model.cancelRecording(id) }.font(.caption)
            }
        }
    }

    private func caption(for button: MicrophoneButton, now: Date) -> String {
        switch button {
        case .openAppToRecord: return "Tap to open lautli and start dictating"
        case .record: return "Tap to dictate"
        case .busy: return "Transcribing…"
        case .stop:
            guard case .recording(_, let startedAt)? = model.snapshot?.phase else { return "Recording" }
            return "Recording " + Duration.seconds(max(0, now.timeIntervalSince(startedAt).rounded()))
                .formatted(.time(pattern: .minuteSecond))
        }
    }

    private var keyRow: some View {
        HStack(spacing: 6) {
            if showsNextKeyboard {
                key(systemImage: "globe", label: "Next keyboard", action: model.nextKeyboard)
            }
            Button { model.type(" ") } label: {
                Text("space").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            key(systemImage: "delete.left", label: "Delete", action: model.deleteBackward)
            key(systemImage: "return", label: "Return") { model.type("\n") }
        }
    }

    private func key(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
    }
}

private extension MicrophoneButton {
    var symbol: String {
        switch self {
        case .openAppToRecord, .record: "mic.fill"
        case .stop: "stop.fill"
        case .busy: "ellipsis"
        }
    }

    var isStop: Bool { if case .stop = self { true } else { false } }

    var accessibilityLabel: String {
        switch self {
        case .openAppToRecord: "Start dictation in lautli"
        case .record: "Start dictation"
        case .stop: "Stop dictation"
        case .busy: "Transcribing"
        }
    }
}
