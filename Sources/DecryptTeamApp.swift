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
                ZStack { AppBackground(); ProgressView() }
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
        ZStack(alignment: .bottom) {
            AppBackground()
            // every tab stays alive, so a search or a half-filled form is still there when you come back
            screen(.home) { HomeView() }
            screen(.search) { SearchView() }
            screen(.repos) { ReposView() }
            screen(.settings) { SettingsView() }
            FloatingTabBar()
        }
        .sheet(isPresented: $store.showQuickBuild) { QuickBuildView() }
        .sheet(isPresented: $store.showTools) { ToolsHubView() }
    }

    private func screen<V: View>(_ tab: AppTab, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 84) }
            .opacity(store.tab == tab ? 1 : 0)
            .allowsHitTesting(store.tab == tab)
            .accessibilityHidden(store.tab != tab)
    }
}
