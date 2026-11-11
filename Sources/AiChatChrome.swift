import SwiftUI
import UIKit

// MARK: - Floating glass styling (ChatGPT-style chrome)

extension View {
    /// A translucent, blurred shape with a hairline highlight — the floating-button look.
    func aiGlass<S: InsettableShape>(_ shape: S) -> some View {
        // a flat translucent fill — no live blur or big shadow, which is what made scrolling stutter while streaming
        self
            .background(shape.fill(Color(white: 0.115, opacity: 0.95)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5))
    }
    func aiGlassCircle(_ size: CGFloat = 44) -> some View {
        self.frame(width: size, height: size).aiGlass(Circle())
    }
}

// MARK: - Chat transcript export

extension AiDecryptViewModel {
    var currentTitle: String {
        conversations.first(where: { $0.id == currentID })?.title ?? "New chat"
    }
}

// MARK: - Sidebar drawer

/// The slide-in drawer: quick actions, your activity footprint (rendered as chat markdown), a big "Chat" button and a settings circle.
struct AiSidebar: View {
    @ObservedObject var vm: AiDecryptViewModel
    let onClose: () -> Void

    @EnvironmentObject private var session: Session
    @EnvironmentObject private var store: RepoStore
    @State private var query = ""
    @State private var searching = false
    @State private var showEdits = false
    @ObservedObject private var activity = ActivityStore.shared
    @ObservedObject private var live = LiveSync.shared
    @State private var openScreen: LiveScreen?
    @FocusState private var searchFocused: Bool


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if searching {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search activity", text: $query)
                            .focused($searchFocused)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .aiGlass(Capsule())
                } else {
                    Text("Uncrypt").font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                    Spacer()
                }
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { searching.toggle() }
                    if searching { searchFocused = true } else { query = ""; searchFocused = false }
                } label: {
                    Image(systemName: searching ? "xmark" : "magnifyingglass")
                        .font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                        .aiGlassCircle(46)
                }
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    profileHeader
                    action("rectangle.grid.2x2.fill", "Hub", detail: "Opened the hub") { open(.hub) }
                    action("circle.grid.3x3.fill", "Browse", detail: "Opened your sources · \(store.repos.count) repo\(store.repos.count == 1 ? "" : "s")") { open(.browse) }
                    action("square.grid.2x2.fill", "Library", detail: "Opened the app library · \(store.apps.count) app\(store.apps.count == 1 ? "" : "s") indexed") { open(.library) }
                    action(UIImage(systemName: "signature") != nil ? "signature" : "pencil.and.scribble", "Signed", detail: "Opened signed builds · \(SignedStore.shared.items.count) build\(SignedStore.shared.items.count == 1 ? "" : "s")") { open(.signed) }
                    action("pencil.tip.crop.circle", "Signer", detail: "Checked signing readiness") { open(.signer) }
                    action("lock.open", "Decrypt", detail: "Opened Decrypt & Inject") { open(.decrypt) }
                    action("checkmark.seal", "Certificate", detail: "Opened certificates") { open(.certificate) }
                    action("square.stack.3d.up", "Batch", detail: "Opened batch inject") { open(.batch) }
                    action("paintpalette", "Theme", detail: "Opened theme") { open(.theme) }
                    action("iphone.and.arrow.forward", "Install", detail: "Opened native install setup") { open(.install) }
                    action("wrench.and.screwdriver", "Tools", detail: "Opened the tools hub") { open(.tools) }
                    if vm.latestReconProject != nil { action("plus.forwardslash.minus", "Code edits") { showEdits = true } }
                    ForEach((live.config.screens ?? []).filter { ($0.show ?? ["sidebar"]).contains("sidebar") }) { s in
                        action(s.icon ?? "square.grid.2x2", s.title) { openScreen = s }
                    }

                    HStack {
                        header("Activity")
                        Spacer()
                        if !activity.entries.isEmpty {
                            Button("Clear") { activity.clear() }
                                .font(.system(size: 15)).foregroundStyle(.secondary).padding(.trailing, 12).padding(.top, 14)
                        }
                    }
                    MarkdownView(activity.markdown(matching: query))
                        .padding(.horizontal, 12).padding(.bottom, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 90)
                }
                .padding(.horizontal, 8)
            }
            .scrollDismissesKeyboard(.immediately)
            .sheet(item: $openScreen) { LiveScreenSheet(screen: $0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            HStack {
                Button { vm.newChat(); store.screen = nil; onClose() } label: {
                    Label("Chat", systemImage: "square.and.pencil")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.dtOnAccent)
                        .padding(.horizontal, 26).padding(.vertical, 14)
                        .background(Capsule().fill(Color.dtAccent))
                        .shadow(color: Color.dtAccent.opacity(0.35), radius: 12, y: 4)
                }
                Spacer()
                Button { open(.settings) } label: {
                    Image(systemName: "gearshape").font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                        .aiGlassCircle(52)
                }
            }
            .padding(.horizontal, 18).padding(.bottom, 14).padding(.top, 20)
            .background(LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
        }
        .sheet(isPresented: $showEdits) {
            if let proj = vm.latestReconProject { AiEditHistorySheet(jobID: proj.jobID, name: proj.name) }
        }
    }

    /// Telegram photo + username at the top of the list; "Guest" when nobody is signed in.
    private var profileHeader: some View {
        HStack(spacing: 14) {
            profileAvatar
            VStack(alignment: .leading, spacing: 2) {
                Text(session.username ?? "Guest")
                    .font(.system(size: 19, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if session.signedIn {
                    Text(session.role.capitalized).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 10)
    }

    @ViewBuilder private var profileAvatar: some View {
        let fallback = Circle().fill(Color.dtAccent.opacity(0.32))
            .overlay(
                Group {
                    if let u = session.username, let c = u.first {
                        Text(String(c).uppercased()).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                    } else {
                        Image(systemName: "person.fill").font(.system(size: 20)).foregroundStyle(.white.opacity(0.8))
                    }
                }
            )
        if session.signedIn, let url = session.photoURL {
            AsyncImage(url: url) { phase in
                if let img = phase.image { img.resizable().scaledToFill() } else { fallback }
            }
            .frame(width: 46, height: 46).clipShape(Circle())
        } else {
            fallback.frame(width: 46, height: 46)
        }
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.top, 22).padding(.bottom, 6)
    }

    /// Opens a page full screen; inside the host this just swaps the page and keeps it on top.
    private func open(_ s: AppScreen) {
        store.screen = s
        onClose()
    }

    private func action(_ icon: String, _ title: String, detail: String? = nil, _ run: @escaping () -> Void) -> some View {
        Button { ActivityStore.shared.log(title, detail); run() } label: {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.system(size: 20, weight: .regular)).frame(width: 28)
                Text(title).font(.system(size: 19))
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


// MARK: - Full-screen page host

/// Shows the chosen menu page full screen with the same sidebar underneath: tap the menu button and the
/// drawer slides over the page you are on, and picking another item swaps pages without going back to chat.
struct ScreenHost: View {
    @ObservedObject var vm: AiDecryptViewModel
    @EnvironmentObject private var store: RepoStore
    @EnvironmentObject private var session: Session
    @State private var drawer = false
    @ObservedObject private var theme = UserTheme.shared      // redraws with the new accent; never rebuilds the page

    var body: some View {
        GeometryReader { geo in
            let sw = geo.size.width * 0.82
            ZStack(alignment: .leading) {
                AppBackground().ignoresSafeArea()
                AiSidebar(vm: vm, onClose: { set(false) }).frame(width: sw)
                    .opacity(drawer ? 1 : 0).allowsHitTesting(drawer)      // only there while the menu is open
                page
                    .background(AppBackground())
                    // masked past the safe area: clipping to the page's own frame cut its background off above the home indicator, and the menu behind showed through
                    .mask { RoundedRectangle(cornerRadius: drawer ? 32 : 0, style: .continuous).ignoresSafeArea() }
                    .overlay {
                        if drawer {
                            Color.black.opacity(0.4)
                                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                                .contentShape(Rectangle())
                                .onTapGesture { set(false) }
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if !drawer && showsFloatingMenu {
                            Button { set(true) } label: {
                                Image(systemName: "line.3.horizontal").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                                    .aiGlassCircle(38)
                            }
                            .padding(.leading, 16).padding(.bottom, 18)
                        }
                    }
                    .shadow(color: .black.opacity(drawer ? 0.5 : 0), radius: 18)
                    .offset(x: drawer ? sw : 0)
            }
        }
        .preferredColorScheme(.dark)
        .tint(.dtAccent)
        .sheet(item: Binding(get: { store.screen != nil ? store.pickedApp : nil }, set: { store.pickedApp = $0 })) { app in
            AppPageView(app: app).environmentObject(store).environmentObject(session)
        }
        .onChange(of: store.hostDrawerTick) { _ in set(true) }
    }

    /// Browse, Library and Signed already carry the chat-style menu button in their own top bar.
    private var showsFloatingMenu: Bool {
        guard let s = store.screen else { return true }
        return !(s == .browse || s == .library || s == .signed)
    }

    private func set(_ open: Bool) {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) { drawer = open }
    }

    @ViewBuilder private var page: some View {
        switch store.screen ?? .hub {
        case .hub: HubView()
        case .browse: ReposView()
        case .library: SearchView()
        case .signed: SignedView()
        case .signer: SignerView()
        case .decrypt: QuickBuildView()
        case .certificate: CertificateView()
        case .batch: BatchView()
        case .theme: ThemeScreen()
        case .install: DeviceSetupView()
        case .tools: ToolsHubView()
        case .settings: AiSettingsView(vm: vm)
        }
    }
}
