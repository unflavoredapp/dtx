import SwiftUI

/// What can sit on the right of the top bar.
enum BarAction {
    case search                         // opens the search field under the bar
    case lock                           // starts a Decrypt & Inject
    case icon(String, () -> Void)
    case text(String, () -> Void)
    case label(String)                  // plain text, not a button
    case menu(String, [(String, () -> Void)])   // an icon that opens a list of choices
}

/// The bar at the top of every main screen: palette on the left, the screen's title in the middle, actions on the right,
/// and a second row with a short line of text (like a count) and your account.
struct TopBar: View {
    @EnvironmentObject var store: RepoStore
    @EnvironmentObject var session: Session
    let tab: AppTab
    /// nil shows the Uncrypt name with the logo; any other text is the screen's title.
    var title: String? = nil
    var strip: String? = nil
    var actions: [BarAction] = []
    /// On a pushed screen: the label of the back button (it replaces the palette), and an icon next to the title.
    var back: String? = nil
    var titleIcon: URL? = nil
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var open: Bool { store.searchOpen && store.tab == tab }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                HStack(spacing: 14) {
                    if let back {
                        Button { store.closeSearch(); dismiss() } label: {
                            HStack(spacing: 4) { Image(systemName: "chevron.left").font(.system(size: 20, weight: .bold)); Text(back).font(.system(size: 22, weight: .semibold)) }
                        }
                    } else {
                        Button { store.closeSearch(); store.tab = .settings } label: { Image(systemName: "paintpalette.fill").font(.system(size: 20, weight: .semibold)) }
                            .accessibilityLabel("Appearance and settings")
                    }
                    Spacer(minLength: 0)
                    ForEach(Array(actions.enumerated()), id: \.offset) { item in actionView(item.element) }
                }
                .foregroundStyle(Color.dtAccent)
                HStack(spacing: 8) {
                    if title == nil {
                        Image("Logo").resizable().frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else if let titleIcon {
                        AppIconView(url: titleIcon, name: title ?? "", size: 36)
                    }
                    Group {
                        if let title { Text(title).foregroundColor(.white) }
                        else { Text("Un").foregroundColor(.white) + Text("crypt").foregroundColor(.dtAccent) }
                    }
                    .font(.system(size: 22, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                }
                .allowsHitTesting(false)
            }
            .padding(.horizontal, 6)

            HStack {
                if let strip { Text(strip).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7).padding(.leading, 8) }
                Spacer()
                Menu {
                    Text("Signed in as " + (session.username ?? ""))
                    Button("Sign out", role: .destructive) { Task { await session.signOut() } }
                } label: {
                    HStack(spacing: 8) {
                        Text(String((session.username ?? "?").prefix(1)).uppercased())
                            .font(.system(size: 15, weight: .heavy)).foregroundStyle(.black)
                            .frame(width: 34, height: 34).background(Circle().fill(Color.dtAccent))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(session.username ?? "Account").font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.dtYellow).lineLimit(1).frame(maxWidth: 110, alignment: .leading)
                            Text(session.staff ? "STAFF" : "BETA").font(.system(size: 10, weight: .heavy, design: .monospaced)).foregroundStyle(Color.dtAccent)
                        }
                        Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    }
                    .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 5)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.35)))

            if open {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search apps in your repos…", text: $store.searchText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search).focused($focused)
                    if !store.searchText.isEmpty {
                        Button { store.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .overlay(Capsule().stroke(Color.dtAccent.opacity(0.5), lineWidth: 1))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 8)
        .glassPanel(radius: 30)
        .onChange(of: store.searchOpen) { isOpen in
            if isOpen && store.tab == tab { DispatchQueue.main.async { focused = true } } else { focused = false }
        }
    }

    @ViewBuilder private func actionView(_ a: BarAction) -> some View {
        switch a {
        case .search:
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if store.searchOpen { store.closeSearch() } else { store.searchOpen = true }
                }
            } label: { Image(systemName: open ? "xmark" : "magnifyingglass").font(.system(size: 20, weight: .semibold)) }
                .accessibilityLabel("Search apps")
        case .lock:
            Button { store.showQuickBuild = true } label: { Image(systemName: "lock.fill").font(.system(size: 20, weight: .semibold)) }
                .accessibilityLabel("Start a build")
        case .icon(let name, let run):
            Button(action: run) { Image(systemName: name).font(.system(size: 22, weight: .semibold)) }
        case .text(let t, let run):
            Button(action: run) { Text(t).font(.system(size: 19, weight: .semibold)) }
        case .label(let t):
            Text(t).font(.system(size: 15, design: .monospaced)).foregroundStyle(.secondary)
        case .menu(let name, let items):
            Menu {
                ForEach(Array(items.enumerated()), id: \.offset) { item in Button(item.element.0, action: item.element.1) }
            } label: { Image(systemName: name).font(.system(size: 22, weight: .semibold)) }
        }
    }
}

/// Results under the search field: 10 at a time, the next 10 load as you scroll.
struct SearchDropdown: View {
    @EnvironmentObject var store: RepoStore
    @ObservedObject var searcher: AppSearcher

    var body: some View {
        if store.searchText.trimmingCharacters(in: .whitespaces).count >= 2 {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if searcher.shown.isEmpty {
                        if searcher.searching { ProgressView().padding(.vertical, 22) }
                        else { Text("No apps found in your repos.").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 22) }
                    }
                    ForEach(searcher.shown) { app in
                        Button { store.pickedApp = app; store.closeSearch() } label: {
                            HStack(spacing: 12) {
                                AppIconView(url: app.icon, name: app.name, size: 40)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                                    Text([app.current.map { "v" + $0.version }, app.repoName].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8).padding(.horizontal, 6)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Color.dtLine)
                    }
                    if searcher.hasMore { ProgressView().padding(.vertical, 12).onAppear { searcher.loadMore() } }
                    else if searcher.total > 0 { Text("\(formatCount(Int64(searcher.total))) result\(searcher.total == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8) }
                }
                .padding(.horizontal, 8)
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: false)
            .glassPanel(radius: 24)
            .transition(.opacity)
        }
    }
}

struct BarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct TopBarHost: ViewModifier {
    @EnvironmentObject var store: RepoStore
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    let tab: AppTab
    let title: String?
    let strip: String?
    let actions: [BarAction]
    let back: String?
    let titleIcon: URL?
    @State private var barHeight: CGFloat = 64

    private var searchOpen: Bool { store.searchOpen && store.tab == tab }

    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: barHeight) }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    chatBar
                        .background(GeometryReader { g in Color.clear.preference(key: BarHeightKey.self, value: g.size.height + 8) })
                    if searchOpen {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search apps in your repos…", text: $store.searchText)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search).focused($searchFocused)
                            if !store.searchText.isEmpty {
                                Button { store.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .aiGlass(Capsule())
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        SearchDropdown(searcher: store.searcher)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.top, 6)
                .animation(.easeInOut(duration: 0.2), value: store.searchOpen)
            }
            .onPreferenceChange(BarHeightKey.self) { barHeight = $0 }
            .onChange(of: store.searchOpen) { isOpen in
                if isOpen && store.tab == tab { DispatchQueue.main.async { searchFocused = true } } else { searchFocused = false }
            }
    }

    /// The same buttons as the chat screen: a round menu button on the left, compose + more in a pill on the right.
    private var chatBar: some View {
        ZStack {
            HStack(alignment: .top) {
                Button {
                    store.closeSearch()
                    if back == nil, store.screen != nil { store.hostDrawerTick += 1; return }   // stay on this page, slide the menu over it
                    dismiss()
                    if back == nil { store.sidebarTick += 1 }
                } label: {
                    Image(systemName: back == nil ? "line.3.horizontal" : "chevron.left")
                        .font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                        .aiGlassCircle(46)
                }
                .accessibilityLabel(back == nil ? "Menu" : "Back")
                Spacer()
                HStack(spacing: 0) {
                    Button { store.closeSearch(); store.screen = nil; dismiss(); store.newChatTick += 1 } label: {
                        Image(systemName: "square.and.pencil").font(.system(size: 19, weight: .medium)).foregroundStyle(.white)
                            .frame(width: 50, height: 46)
                    }
                    .accessibilityLabel("New chat")
                    Menu {
                        ForEach(Array(actions.enumerated()), id: \.offset) { item in menuItems(item.element) }
                        Divider()
                        Text("Signed in as " + (session.username ?? "guest"))
                        if session.signedIn { Button("Sign out", role: .destructive) { Task { await session.signOut() } } }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 50, height: 46)
                    }
                    .accessibilityLabel("More")
                }
                .aiGlass(Capsule())
            }
            if let title {
                // app icon, then the name, with the count centred under it
                VStack(spacing: 1) {
                    HStack(spacing: 7) {
                        if let titleIcon { AppIconView(url: titleIcon, name: title, size: 28) }
                        Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    if let strip {
                        Text(strip).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: 170)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private func menuItems(_ a: BarAction) -> some View {
        switch a {
        case .search:
            Button { store.tab = tab; store.searchOpen.toggle() } label: { Label("Search", systemImage: "magnifyingglass") }
        case .lock:
            Button { store.showQuickBuild = true } label: { Label("Decrypt & Inject", systemImage: "lock.open") }
        case .icon(let name, let run):
            Button(action: run) { Label(name == "plus" ? "Add" : "Action", systemImage: name) }
        case .text(let t, let run):
            Button(t, action: run)
        case .label(let t):
            Text(t)
        case .menu(let name, let items):
            ForEach(Array(items.enumerated()), id: \.offset) { item in
                Button { item.element.1() } label: { Label(item.element.0, systemImage: name) }
            }
        }
    }
}

extension View {
    /// Puts the shared top bar above a screen and hides the system navigation bar. Pushed screens keep their own.
    func withTopBar(_ tab: AppTab, title: String? = nil, strip: String? = nil, actions: [BarAction]? = nil, back: String? = nil, titleIcon: URL? = nil) -> some View {
        modifier(TopBarHost(tab: tab, title: title, strip: strip, actions: actions ?? (tab == .home ? [.search, .lock] : [.search]), back: back, titleIcon: titleIcon))
    }
}
