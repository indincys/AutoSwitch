import AppKit
import Foundation

final class LockScreenMonitor: NSObject {
    private let callback: @MainActor @Sendable (FocusEvent) -> Void
    private var tokens: [NSObjectProtocol] = []
    private let notificationCenter = NSWorkspace.shared.notificationCenter

    init(callback: @escaping @MainActor @Sendable (FocusEvent) -> Void) {
        self.callback = callback
        super.init()
    }

    deinit {
        for token in tokens {
            notificationCenter.removeObserver(token)
        }
    }

    func start() {
        guard tokens.isEmpty else { return }
        let callback = self.callback
        let notifications: [(NSNotification.Name, FocusEvent)] = [
            (NSWorkspace.screensDidWakeNotification, .screenWoke),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionActive)
        ]

        for (name, event) in notifications {
            let token = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    callback(event)
                }
            }
            tokens.append(token)
        }
    }
}
