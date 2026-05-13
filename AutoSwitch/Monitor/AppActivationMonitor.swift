import AppKit
import Foundation

final class AppActivationMonitor: NSObject {
    private let callback: @MainActor @Sendable (String?) -> Void
    private var token: NSObjectProtocol?
    private let notificationCenter = NSWorkspace.shared.notificationCenter

    init(callback: @escaping @MainActor @Sendable (String?) -> Void) {
        self.callback = callback
        super.init()
    }

    deinit {
        if let token {
            notificationCenter.removeObserver(token)
        }
    }

    func start() {
        guard token == nil else { return }
        let callback = self.callback
        token = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in
                callback(bundleID)
            }
        }
    }
}
