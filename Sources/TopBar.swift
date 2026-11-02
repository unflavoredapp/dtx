import SwiftUI

/// The bar at the top of every main screen: a glass panel with the logo, the screen's title, search and build buttons,
/// and your account on a second row. The search button opens a field right under the bar, with results dropping down.
struct TopBar: View {
    @EnvironmentObject var store: RepoStore
    @EnvironmentObject var session: Session
    let tab: AppTab
    /// nil shows the Decrypt.Team name; any other text is the screen's title.
    var title: String? = nil
    @FocusState private var focused: Bool

    private var open: Bool { store.searchOpen && store.tab == tab }

    var body: some View { bar }

    private var bar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { store.closeSearch(); store.tab = .settings } label: { Image(systemName: "paintpalette.fill").font(.system(size: 20, weight: .semibold)) }
                    .accessibilityLabel("Appearance and settings")
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if tab == .home {
                        Image("Logo").resizable().frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    Group {
                        if let title { Text(title).foregroundColor(.white) }
                        else { Text("Decrypt.").foregroundColor(.white) + Text("Team").foregroundColor(.dtAccent) }
                    }
                    .font(.system(size: 22, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if store.searchOpen { store.closeSearch() } else { store.searchOpen = true }
                    }
                } label: { Image(systemName: open ? "xmark" : "magnifyingglass").font(.system(size: 20, weight: .semibold)) }
                    .accessibilityLabel("Search apps")
                Button { store.showQuickBuild = true } label: { Image(systemName: "lock.fill").font(.system(size: 20, weight: .semibold)) }
                    .accessibilityLabel("Start a build")
            }
            .foregroundStyle(Color.dtAccent)
            .padding(.horizontal, 6)

            HStack {
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
    @State private var barHeight: CGFloat = 140

    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: barHeight) }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    TopBar(tab: tab, title: title)
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
    func withTopBar(_ tab: AppTab, title: String? = nil) -> some View { modifier(TopBarHost(tab: tab, title: title)) }
}
