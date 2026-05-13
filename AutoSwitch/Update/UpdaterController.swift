import Foundation
import Sparkle

@MainActor
final class UpdaterController: ObservableObject {
    @Published private(set) var lastCheckMessage = "Not checked"

    private let controller: SPUStandardUpdaterController
    private let updaterDelegate = SparkleUpdaterDelegate()
    private let userDriver = SparkleUserDriver()

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var feedURL: URL? {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL").flatMap { value in
            if let url = value as? URL {
                return url
            }
            if let string = value as? String {
                return URL(string: string)
            }
            return nil
        }
    }
    var publicEDKey: String? {
        Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
    }
    var isFeedPlaceholder: Bool {
        feedURL?.host == "example.com"
    }
    var isPublicKeyPlaceholder: Bool {
        guard let publicEDKey else { return true }
        return publicEDKey.isEmpty || publicEDKey.contains("REPLACE_ME")
    }
    var isConfiguredForRelease: Bool {
        feedURL != nil && !isFeedPlaceholder && !isPublicKeyPlaceholder
    }

    init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: userDriver
        )
        controller.updater.automaticallyChecksForUpdates = false
        controller.updater.automaticallyDownloadsUpdates = false
    }

    func startUpdater() {
        guard isConfiguredForRelease else {
            lastCheckMessage = "Release configuration is missing."
            return
        }
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard isConfiguredForRelease else {
            lastCheckMessage = "Release configuration is missing."
            return
        }
        lastCheckMessage = "Update check requested."
        controller.checkForUpdates(nil)
    }
}

private final class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {}

private final class SparkleUserDriver: NSObject, SPUStandardUserDriverDelegate {}
