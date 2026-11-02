import SwiftUI

@main
struct DecryptTeamApp: App {
    @StateObject private var store = RepoStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: RepoStore

    var body: some View {
        TabView(selection: $store.tab) {
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(AppTab.search)
            StudioView()
                .tabItem { Label("Studio", systemImage: "wand.and.stars") }
                .tag(AppTab.studio)
            ReposView()
                .tabItem { Label("Repos", systemImage: "square.stack.3d.up") }
                .tag(AppTab.repos)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .task { await store.refresh() }
    }
}
