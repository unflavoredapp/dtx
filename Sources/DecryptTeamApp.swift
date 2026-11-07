import SwiftUI

@main
struct DecryptTeamApp: App {
    @StateObject private var store = RepoStore()
    @StateObject private var session = Session()
    @ObservedObject private var theme = UserTheme.shared

    init() {
        // Must register before launch finishes (pairing keeps running via a continued-processing task).
        DevicePairingService.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(session)
                .preferredColorScheme(.dark)
                .tint(.dtAccent)
                .background(TouchProbe())
                .task { AppTheme.shared.startCycleIfNeeded() }
                .overlay(alignment: .bottom) { VStack(spacing: 8) { UndoUninstallBanner(); NativeInstallBanner() } }
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
                chatHome
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
        .onChange(of: scenePhase) { phase in if phase == .active { Task { await VPNReconnectCoordinator.shared.appBecameActive() }; session.nudge(); if session.allowed { Task { await live.syncIfDue() } } } }
        // Pops up over whatever screen is already loading underneath, right after a Telegram login succeeds —
        // never a separate full screen, so the app behind it is already settling in while this shows.
        .overlay { if session.justSignedIn { WelcomePopup().environmentObject(session) } }
    }

    private var chatHome: some View {
        AiDecryptChatView(embedded: true)
            .environmentObject(store)
            .environmentObject(session)
            .sheet(isPresented: $store.showQuickBuild) { QuickBuildView() }
            .sheet(isPresented: $store.showTools) { ToolsHubView() }
            .sheet(item: $store.pickedApp) { app in
                NavigationStack {
                    AppDetailView(app: app)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { store.pickedApp = nil } } }
                }
                .preferredColorScheme(.dark)
            }
    }
}
