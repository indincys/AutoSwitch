import SwiftUI

struct SettingsScene: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }

            AppRulesTab()
                .tabItem { Label("Apps", systemImage: "app.badge") }

            SpotlightTab()
                .tabItem { Label("Launchers", systemImage: "magnifyingglass") }
        }
        .frame(minWidth: AppState.settingsWindowMinimumContentSize.width,
               minHeight: AppState.settingsWindowMinimumContentSize.height)
        .onAppear {
            AppState.shared.permissionsManager.refresh()
            AppState.shared.loginItemManager.refresh()
            AppState.shared.inputSourceController.refreshInputSources()
        }
    }
}
