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
    /// nil shows the Decrypt.Team name with the logo; any other text is the screen's title.
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
                        else { Text("Decrypt.").foregroundColor(.white) + Text("Team").foregroundColor(.dtAccent) }
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
    let tab: AppTab
    let title: String?
    let strip: String?
    let actions: [BarAction]
    let back: String?
    let titleIcon: URL?
    @State private var barHeight: CGFloat = 140

    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: barHeight) }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    TopBar(tab: tab, title: title, strip: strip, actions: actions, back: back, titleIcon: titleIcon)
                        .background(GeometryReader { g in Color.clear.preference(key: BarHeightKey.self, value: g.size.height + 10) })
                    if store.searchOpen && store.tab == tab { SearchDropdown(searcher: store.searcher) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.top, 4)
                .animation(.easeInOut(duration: 0.2), value: store.searchOpen)
            }
            .onPreferenceChange(BarHeightKey.self) { barHeight = $0 }
    }
}

extension View {
    /// Puts the shared top bar above a screen and hides the system navigation bar. Pushed screens keep their own.
    func withTopBar(_ tab: AppTab, title: String? = nil, strip: String? = nil, actions: [BarAction]? = nil, back: String? = nil, titleIcon: URL? = nil) -> some View {
        modifier(TopBarHost(tab: tab, title: title, strip: strip, actions: actions ?? (tab == .home ? [.search, .lock] : [.search]), back: back, titleIcon: titleIcon))
    }
}
