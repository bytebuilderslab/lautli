import Foundation

/// Darwin notifications are the only way to wake the other process (app or keyboard) without a server.
public enum DarwinSignalCenter {
    public static func post(_ signal: DictationSignal) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(signal.rawValue as CFString),
            nil, nil, true
        )
    }
}

/// Calls `handler` on the main queue for every post of `signal` while this object is alive.
public final class DarwinSignalObserver: @unchecked Sendable {
    private let signal: DictationSignal
    private let handler: @MainActor () -> Void

    public init(_ signal: DictationSignal, handler: @escaping @MainActor () -> Void) {
        self.signal = signal
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let receiver = Unmanaged<DarwinSignalObserver>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { MainActor.assumeIsolated { receiver.handler() } }
            },
            signal.rawValue as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(signal.rawValue as CFString),
            nil
        )
    }
}
