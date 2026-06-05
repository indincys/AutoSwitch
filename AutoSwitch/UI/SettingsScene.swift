import SwiftUI

struct SettingsScene: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("通用", systemImage: "gearshape") }

            AppRulesTab()
                .tabItem { Label("应用", systemImage: "app.badge") }
        }
        .frame(minWidth: AppState.settingsWindowMinimumContentSize.width,
               minHeight: AppState.settingsWindowMinimumContentSize.height)
        .onAppear {
            appState.permissionsManager.refresh()
            appState.loginItemManager.refresh()
            appState.inputSourceController.refreshInputSources()
        }
    }
}
