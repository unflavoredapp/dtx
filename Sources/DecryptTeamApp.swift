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
    @State private var chatVM = AiDecryptViewModel()   // not observed here, so typing never re-renders the whole app root

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
        AiDecryptChatView(embedded: true, viewModel: chatVM)
            .environmentObject(store)
            .environmentObject(session)
            // Menu pages are full screen and hosted here, outside the chat's theme-refresh id, so they never dismiss themselves.
            .fullScreenCover(isPresented: Binding(get: { store.screen != nil }, set: { if !$0 { store.screen = nil } })) {
                ScreenHost(vm: chatVM).environmentObject(store).environmentObject(session)
            }
            .onChange(of: store.showQuickBuild) { on in if on { store.showQuickBuild = false; store.screen = .decrypt } }
            .onChange(of: store.showTools) { on in if on { store.showTools = false; store.screen = .tools } }
            .sheet(item: Binding(get: { store.screen == nil ? store.pickedApp : nil }, set: { store.pickedApp = $0 })) { app in
                AppPageView(app: app).environmentObject(store).environmentObject(session)
            }
    }
}
