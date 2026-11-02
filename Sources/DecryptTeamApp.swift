import SwiftUI

@main
struct DecryptTeamApp: App {
    @StateObject private var store = RepoStore()
    @StateObject private var session = Session()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(session)
                .preferredColorScheme(.dark)
                .tint(.dtAccent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: RepoStore
    @EnvironmentObject var session: Session

    var body: some View {
        Group {
            if !session.checked {
                ZStack { Color.dtBG.ignoresSafeArea(); ProgressView() }
            } else if !session.allowed {
                OnboardingView()
            } else {
                mainTabs
            }
        }
        .task { await store.refresh(); await session.refresh() }
        .animation(.easeInOut(duration: 0.25), value: session.allowed)
    }

    private var mainTabs: some View {
        TabView(selection: $store.tab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
                .tag(AppTab.home)
            SearchView()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                .tag(AppTab.search)
            ReposView()
                .tabItem { Label("Repos", systemImage: "square.stack.3d.up") }
                .tag(AppTab.repos)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .sheet(isPresented: $session.showLogin) { LoginSheet() }
    }
}
