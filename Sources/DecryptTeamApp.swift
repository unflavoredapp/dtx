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
                .onOpenURL { url in if url.scheme == "decryptteam" { session.nudge() } }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: RepoStore
    @EnvironmentObject var session: Session
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var live = LiveSync.shared

    var body: some View {
        Group {
            if !session.checked {
                ZStack { AppBackground(); ProgressView() }
            } else if !session.allowed {
                OnboardingView()
            } else {
                mainTabs.id(live.themeRev)      // rebuilt only when a live release changes the accent colour
            }
        }
        .task { await session.refresh() }
        // the repos are only fetched once you are in, so signing in never waits behind a big download
        .task(id: session.allowed) { if session.allowed { await store.refresh() } }
        .task(id: session.allowed) {
            guard session.allowed else { return }
            await live.syncIfDue()
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            live.confirmHealthy()
        }
        .animation(.easeInOut(duration: 0.25), value: session.allowed)
        .onChange(of: scenePhase) { phase in if phase == .active { session.nudge(); if session.allowed { Task { await live.syncIfDue() } } } }
    }

    private var mainTabs: some View {
        ZStack(alignment: .bottom) {
            AppBackground()
            // every tab stays alive, so a search or a half-filled form is still there when you come back
            screen(.home) { HomeView() }
            screen(.search) { SearchView() }
            screen(.repos) { ReposView() }
            screen(.signed) { SignedView() }
            screen(.settings) { SettingsView() }
            FloatingTabBar()
        }
        .sheet(isPresented: $store.showQuickBuild) { QuickBuildView() }
        .sheet(isPresented: $store.showTools) { ToolsHubView() }
        .sheet(isPresented: $store.showAiDecrypt) { AiDecryptChatView().environmentObject(store) }
        .sheet(item: $store.pickedApp) { app in
            NavigationStack {
                AppDetailView(app: app)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { store.pickedApp = nil } } }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func screen<V: View>(_ tab: AppTab, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 84) }
            .opacity(store.tab == tab ? 1 : 0)
            .allowsHitTesting(store.tab == tab)
            .accessibilityHidden(store.tab != tab)
    }
}
