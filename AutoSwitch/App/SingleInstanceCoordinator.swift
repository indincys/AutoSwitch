import AppKit
import Darwin
import Foundation
import os.log

final class SingleInstanceCoordinator: NSObject {
    static let openSettingsNotification = Notification.Name("dev.autoswitch.openSettings")

    private let logger = Logger(subsystem: "dev.autoswitch", category: "single-instance")
    private let openSettingsAction: @MainActor () -> Void
    private var lockFileDescriptor: Int32 = -1
    private let lockURL: URL

    init(openSettingsAction: @escaping @MainActor () -> Void) {
        self.openSettingsAction = openSettingsAction
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.lockURL = baseURL
            .appendingPathComponent("AutoSwitch", isDirectory: true)
            .appendingPathComponent("instance.lock")
        super.init()
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        if lockFileDescriptor >= 0 {
            close(lockFileDescriptor)
        }
    }

    func installObserver() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleOpenSettingsNotification(_:)),
            name: Self.openSettingsNotification,
            object: nil
        )
    }

    @objc private func handleOpenSettingsNotification(_ notification: Notification) {
        logger.info("received open settings notification")
        let action = openSettingsAction
        Task { @MainActor in
            action()
        }
    }

    func acquireLockOrSignalExistingInstance() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            logger.error("failed to create lock directory: \(error.localizedDescription, privacy: .public)")
        }

        lockFileDescriptor = open(lockURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard lockFileDescriptor >= 0 else {
            logger.error("failed to open lock file")
            return true
        }

        if flock(lockFileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            logger.info("existing instance detected, signaling open settings")
            DistributedNotificationCenter.default().post(name: Self.openSettingsNotification, object: nil)
            return false
        }

        logger.info("single instance lock acquired")
        return true
    }
}
