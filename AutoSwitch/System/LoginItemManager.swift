import ServiceManagement
import SwiftUI

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    @Published private(set) var lastErrorMessage: String?

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

extension SMAppService.Status {
    var autoswitchDescription: String {
        switch self {
        case .notRegistered:
            return "未启用"
        case .enabled:
            return "已启用"
        case .requiresApproval:
            return "需要批准"
        case .notFound:
            return "未找到"
        @unknown default:
            return "未知"
        }
    }
}
