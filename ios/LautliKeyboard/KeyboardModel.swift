import LautliKit
import Observation
import SwiftUI

/// The keyboard side of the exchange: reads the app's snapshot, issues commands, inserts confirmed text.
@MainActor @Observable
final class KeyboardModel {
    private(set) var snapshot: SessionSnapshot?
    private(set) var notice: String?

    /// Results this keyboard already inserted or discarded. The app may publish the same result again
    /// before it processes the acknowledgement, and it must not be offered twice.
    @ObservationIgnored private var acknowledged: Set<DictationRequestID> = []
    @ObservationIgnored private var snapshotObserver: DarwinSignalObserver?
    @ObservationIgnored private let hasFullAccess: () -> Bool
    @ObservationIgnored private let insertTextIntoField: (String) -> Void
    @ObservationIgnored let deleteBackward: () -> Void
    @ObservationIgnored let nextKeyboard: () -> Void
    @ObservationIgnored private let openContainingApp: (URL) -> Bool

    init(
        hasFullAccess: @escaping () -> Bool,
        insertText: @escaping (String) -> Void,
        deleteBackward: @escaping () -> Void,
        nextKeyboard: @escaping () -> Void,
        openContainingApp: @escaping (URL) -> Bool
    ) {
        self.hasFullAccess = hasFullAccess
        self.insertTextIntoField = insertText
        self.deleteBackward = deleteBackward
        self.nextKeyboard = nextKeyboard
        self.openContainingApp = openContainingApp
        snapshotObserver = DarwinSignalObserver(.snapshotChanged) { [weak self] in self?.refresh() }
    }

    /// A result is only offered while the app that produced it is still running its session.
    var pendingResult: DictationPhase? {
        guard let snapshot, snapshot.isAppListening(at: .now) else { return nil }
        switch snapshot.phase {
        case .transcribed(let id, _), .failed(let id, _):
            return acknowledged.contains(id) ? nil : snapshot.phase
        default:
            return nil
        }
    }

    func microphoneButton(at now: Date) -> MicrophoneButton {
        MicrophoneButton(snapshot: snapshot, now: now)
    }

    func refresh() {
        guard hasFullAccess() else {
            notice = "Turn on Allow Full Access for lautli in Settings to dictate. Typing works without it."
            return
        }
        guard let store = SharedDictationStore.appGroup() else {
            notice = "lautli cannot reach its app. Reinstall lautli."
            return
        }
        do {
            snapshot = try store.readSnapshot()
            notice = nil
        } catch {
            notice = "lautli cannot reach its app. Open lautli and try again."
        }
    }

    func tapMicrophone() {
        refresh()
        guard notice == nil else { return }
        let button = microphoneButton(at: .now)
        guard let command = button.command(for: DictationRequestID()) else { return }
        guard issue(command) else { return }
        if button == .openAppToRecord {
            let opened = URL(string: "lautli://dictate").map(openContainingApp) ?? false
            notice = opened ? nil : "Open lautli to start a dictation session."
        } else {
            DarwinSignalCenter.post(.commandIssued)
        }
    }

    func cancelRecording(_ id: DictationRequestID) {
        if issue(.cancel(id)) { DarwinSignalCenter.post(.commandIssued) }
    }

    func insert(_ text: String, for id: DictationRequestID) {
        guard !acknowledged.contains(id) else { return }
        insertTextIntoField(text)
        acknowledge(id)
    }

    func acknowledge(_ id: DictationRequestID) {
        acknowledged.insert(id)
        if issue(.acknowledge(id)) { DarwinSignalCenter.post(.commandIssued) }
    }

    func type(_ text: String) {
        insertTextIntoField(text)
    }

    private func issue(_ command: DictationCommand) -> Bool {
        guard let store = SharedDictationStore.appGroup() else {
            notice = "lautli cannot reach its app. Reinstall lautli."
            return false
        }
        do {
            try store.writeCommand(IssuedCommand(command, issuedAt: .now))
            return true
        } catch {
            notice = "lautli cannot reach its app. Check that Allow Full Access is on."
            return false
        }
    }
}
