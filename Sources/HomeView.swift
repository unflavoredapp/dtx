import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: RepoStore
    @EnvironmentObject var session: Session
    @State private var query = ""
    @State private var stats: Stats?
    @State private var changes: [ChangelogReply.Entry] = []
    @State private var recent: [RecentReply.Item] = []
    @State private var showChangelog = false
    @State private var showActivity = false
    @State private var slide = 0
    @StateObject private var searcher = AppSearcher()
    @FocusState private var focus: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        hero
                        tools
                    }
                    searchBar
                    if store.onlyDefault { repoNotice }
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        statsRow
                        HStack(alignment: .top, spacing: 12) {
                            changelogCard
                            activityCard
                        }
                        footer
                    } else {
                        resultsList
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 24)
            }
            .background(AppBackground())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: AppEntry.self) { AppDetailView(app: $0) }
            .task { searcher.minChars = 2; await load() }
            .onChange(of: query) { _ in searcher.update(query: query, apps: store.apps) }
            .onChange(of: store.loading) { _ in searcher.update(query: query, apps: store.apps) }
            .refreshable { await load(); await store.refresh() }
            .sheet(isPresented: $showChangelog) { ChangelogView() }
            .sheet(isPresented: $showActivity) { ActivityView(items: recent) }
        }
    }

    // MARK: floating header

    private var header: some View {
        HStack(spacing: 12) {
            Image("Logo").resizable().frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.dtAccent.opacity(0.5)))
            VStack(alignment: .leading, spacing: 1) {
                (Text("Decrypt.").foregroundColor(.white) + Text("Team").foregroundColor(.dtAccent)).font(.title3.weight(.heavy))
                Text("iOS app discovery, decryption and injection tools").font(.caption2).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Rectangle().fill(Color.dtLine).frame(width: 1, height: 38)
            Menu {
                Text("Signed in as " + (session.username ?? ""))
                Button("Sign out", role: .destructive) { Task { await session.signOut() } }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person").foregroundStyle(Color.dtAccent)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(session.username ?? "Account").font(.caption.weight(.bold)).foregroundStyle(.white).lineLimit(1)
                        Text(session.staff ? "STAFF" : "BETA").font(.system(size: 10, weight: .heavy)).foregroundStyle(Color.dtAccent)
                    }
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .glowCapsule()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .glowCapsule(strong: true)
        .padding(.top, 6)
    }

    // MARK: hero banner (swipe for more)

    private struct Slide { let title: String; let text: String; let button: String; let icon: String; let action: () -> Void }

    private var slides: [Slide] {
        [
            Slide(title: "Build • Decrypt • Inject", text: "Create custom IPAs with your dtx.dylib and saved libraries.", button: "Start Build", icon: "lock.open.fill") { store.showQuickBuild = true },
            Slide(title: "Your repos, one search", text: "Add AltStore or SideStore repos and find any app in them.", button: "Add a repo", icon: "square.stack.3d.up.fill") { store.tab = .repos },
            Slide(title: "Analysis tools", text: "Read load commands, bundles and strings of any IPA.", button: "Open tools", icon: "wrench.and.screwdriver.fill") { store.showTools = true },
        ]
    }

    private var hero: some View {
        VStack(spacing: 8) {
            TabView(selection: $slide) {
                ForEach(Array(slides.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(s.title).font(.title2.weight(.heavy)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                            Text(s.text).font(.subheadline).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Button(action: s.action) {
                                HStack(spacing: 6) { Text(s.button).font(.headline); Image(systemName: "chevron.right").font(.subheadline.weight(.bold)) }
                                    .foregroundStyle(.white).padding(.horizontal, 18).padding(.vertical, 10)
                                    .background(Capsule().fill(LinearGradient(colors: [Color.dtAccent, Color(red: 0.95, green: 0.4, blue: 0.05)], startPoint: .top, endPoint: .bottom)))
                                    .shadow(color: Color.dtAccent.opacity(0.5), radius: 10)
                            }
                        }
                        Spacer(minLength: 0)
                        heroArt(s.icon)
                    }
                    .padding(18).padding(.bottom, 8)
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 178)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(LinearGradient(colors: [Color.dtAccent.opacity(0.18), Color.black.opacity(0.45)], startPoint: .topTrailing, endPoint: .bottomLeading)))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(LinearGradient(colors: [Color.dtAccent.opacity(0.9), Color.dtAccent.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5))
            .shadow(color: Color.dtAccent.opacity(0.3), radius: 16)
            HStack(spacing: 6) {
                ForEach(0..<slides.count, id: \.self) { i in
                    Circle().fill(i == slide ? Color.dtAccent : Color.white.opacity(0.25)).frame(width: i == slide ? 8 : 6, height: i == slide ? 8 : 6)
                }
            }
        }
    }

    private func heroArt(_ icon: String) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Color.dtAccent.opacity(0.55 - Double(i) * 0.15), Color.dtAccent.opacity(0.12)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.dtAccent.opacity(0.7), lineWidth: 1))
                    .frame(width: 84, height: 84)
                    .rotationEffect(.degrees(Double(i) * 7 - 7))
                    .offset(x: CGFloat(i) * 8, y: CGFloat(-i) * 7 + 8)
            }
            Image(systemName: icon).font(.system(size: 36, weight: .bold)).foregroundStyle(.white).shadow(color: Color.dtAccent, radius: 8)
        }
        .frame(width: 118, height: 118)
        .shadow(color: Color.dtAccent.opacity(0.4), radius: 14)
    }

    // MARK: featured tools

    private var tools: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                RoundedRectangle(cornerRadius: 2).fill(Color.dtAccent).frame(width: 4, height: 22)
                Text("Featured Tools").font(.title3.weight(.bold))
                Spacer()
                Button { store.tab = .search } label: { HStack(spacing: 3) { Text("Open apps"); Image(systemName: "chevron.right").font(.caption.weight(.bold)) } }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.dtAccent)
            }
            HStack(spacing: 8) {
                toolCard("Find Apps", "Search every repo you added", "magnifyingglass", [.cyan, .blue], nil) { store.tab = .search }
                toolCard("Decrypt & Inject", nil, "lock.open.fill", [.orange, .red], "EXCLUSIVE") { store.showQuickBuild = true }
                toolCard("Repo Studio", "Read repos, pull IPAs and libraries", "square.stack.3d.up.fill", [.purple, .indigo], nil) { store.tab = .repos }
                toolCard("Tools", "CFG viewer, injector and more", "briefcase.fill", [Color(red: 0.2, green: 0.8, blue: 0.45), Color(red: 0.05, green: 0.55, blue: 0.3)], nil) { store.showTools = true }
            }
        }
    }

    private func toolCard(_ title: String, _ sub: String?, _ icon: String, _ colors: [Color], _ badge: String?, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .shadow(color: colors[0].opacity(0.5), radius: 8)
                Text(title).font(.subheadline.weight(.bold)).foregroundStyle(.white).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
                if let sub { Text(sub).font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3) }
                if let badge { Text(badge).font(.system(size: 9, weight: .heavy)).foregroundStyle(Color.dtAccent).padding(.horizontal, 7).padding(.vertical, 3).overlay(Capsule().stroke(Color.dtAccent)) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 142, alignment: .top)
            .padding(.vertical, 10).padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black.opacity(0.4)).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(LinearGradient(colors: [Color.dtAccent.opacity(0.5), Color.dtAccent.opacity(0.1)], startPoint: .top, endPoint: .bottom)))
            .shadow(color: Color.dtAccent.opacity(0.15), radius: 8)
        }
        .buttonStyle(.plain)
    }

    // MARK: search

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search apps in your repos…", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search).focused($focus)
            if !query.isEmpty {
                Button { query = ""; focus = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 15)
        .glowCapsule(strong: true)
    }

    private var repoNotice: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.repos.isEmpty ? "No repos added" : "Searching the Delvek repo").font(.subheadline.bold())
                Text(store.repos.isEmpty ? "Add a repo to search for apps." : "Add your own repo to find more apps.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add a repo") { store.tab = .repos }.buttonStyle(.borderedProminent).tint(.dtAccent)
        }
        .padding(12)
        .background(Color.dtAccent.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.dtAccent))
    }

    private var resultsList: some View {
        LazyVStack(spacing: 0) {
            if searcher.shown.isEmpty {
                if searcher.searching {
                    ProgressView().padding(.vertical, 30)
                } else {
                    Text(query.trimmingCharacters(in: .whitespaces).count < 2 ? "Type an app name to search your repos." : "No apps found in your repos.")
                        .foregroundStyle(.secondary).padding(.vertical, 30)
                }
            }
            ForEach(searcher.shown) { app in
                NavigationLink(value: app) {
                    HStack(spacing: 12) {
                        AppIconView(url: app.icon, name: app.name, size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.headline).foregroundStyle(.white).lineLimit(1)
                            Text([app.current.map { "v" + $0.version }, app.repoName].compactMap { $0 }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                }
                Divider().overlay(Color.dtLine)
            }
            if searcher.hasMore {
                // the next 10 load when this row scrolls into view
                ProgressView().padding(.vertical, 14).onAppear { searcher.loadMore() }
            } else if searcher.total > 0 {
                Text("\(formatCount(Int64(searcher.total))) result\(searcher.total == 1 ? "" : "s")").font(.footnote).foregroundStyle(.secondary).padding(.top, 10)
            }
        }
        .card()
    }

    // MARK: stats

    private var statsRow: some View {
        HStack(spacing: 8) {
            stat("lock", stats?.decrypts?.total, "Total Decrypts")
            stat("square.3.layers.3d", stats?.injections?.total, "Dylib Injections")
            stat("person.2", stats?.visitors?.total, "Total Visitors")
            stat("calendar", stats?.day?.total, "Visitors (24h)")
        }
    }

    private func stat(_ icon: String, _ n: Int64?, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).foregroundStyle(Color.dtAccent)
            Text(n.map { formatCount($0) } ?? "–").font(.title3.weight(.bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(LinearGradient(colors: [Color.dtAccent.opacity(0.5), Color.dtAccent.opacity(0.1)], startPoint: .top, endPoint: .bottom)))
        .shadow(color: Color.dtAccent.opacity(0.15), radius: 6)
    }

    // MARK: changelog and activity

    private func split(_ s: String) -> String {
        if let r = s.range(of: #"^(.{12,70}?[.:])\s+"#, options: .regularExpression) { return String(s[r]).trimmingCharacters(in: .whitespaces) }
        return s
    }

    private var changelogCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Changelog", systemImage: "doc.text").font(.headline).foregroundStyle(.white).labelStyle(OrangeIcon())
                Spacer(minLength: 2)
                Button { showChangelog = true } label: { HStack(spacing: 2) { Text("View All"); Image(systemName: "chevron.right") } }
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.dtAccent)
            }
            if let e = changes.first {
                ForEach(Array(e.items.prefix(3).enumerated()), id: \.offset) { i, item in
                    Divider().overlay(Color.dtLine)
                    Button { showChangelog = true } label: {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    if i == 0 { Text("NEW").font(.system(size: 9, weight: .heavy)).foregroundStyle(Color.dtGreen).padding(.horizontal, 5).padding(.vertical, 1).overlay(Capsule().stroke(Color.dtGreen)) }
                                    Text(e.date).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Text(split(item)).font(.footnote.weight(.semibold)).foregroundStyle(.white).lineLimit(3).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary).padding(.top, 14)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("Nothing here yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recent Activity", systemImage: "waveform.path.ecg").font(.headline).foregroundStyle(.white).labelStyle(OrangeIcon())
            if recent.isEmpty {
                Text("No decrypts yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(recent.prefix(3)) { r in
                Divider().overlay(Color.dtLine)
                HStack(spacing: 8) {
                    AppIconView(url: AppDetailView.https(r.icon), name: r.name, size: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(r.name).font(.footnote.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                        Text("Decrypted" + (r.ver.isEmpty ? "" : " • v" + r.ver)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle").foregroundStyle(Color.dtGreen)
                }
            }
            Button { showActivity = true } label: {
                HStack(spacing: 4) { Text("View All Activity"); Image(systemName: "chevron.right") }
                    .font(.footnote.weight(.bold)).foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(Capsule().fill(Color.dtAccent.opacity(0.15)))
                    .overlay(Capsule().stroke(Color.dtAccent.opacity(0.8)))
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text("BUILT BY").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
            (Text("The ").foregroundColor(.white) + Text("Decrypt.team").foregroundColor(.dtAccent) + Text(" Team").foregroundColor(.white)).font(.subheadline.bold())
        }
        .padding(.top, 4)
    }

    private func load() async {
        async let s: Stats? = try? Api.shared.get("/api/stats")
        async let c: ChangelogReply? = try? Api.shared.get("/api/changelog")
        async let r: RecentReply? = try? Api.shared.get("/api/recent")
        stats = await s
        changes = (await c)?.entries ?? []
        recent = (await r)?.items ?? []
    }
}

struct OrangeIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.icon.foregroundStyle(Color.dtAccent); configuration.title }
    }
}

/// Everything the server decrypted lately, in a list.
struct ActivityView: View {
    @Environment(\.dismiss) private var dismiss
    let items: [RecentReply.Item]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if items.isEmpty { Text("No decrypts yet.").foregroundStyle(.secondary).padding(30) }
                    ForEach(items) { r in
                        HStack(spacing: 12) {
                            AppIconView(url: AppDetailView.https(r.icon), name: r.name, size: 44)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.name).font(.headline).foregroundStyle(.white).lineLimit(1)
                                Text("Decrypted" + (r.ver.isEmpty ? "" : " • v" + r.ver)).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle").foregroundStyle(Color.dtGreen)
                        }
                        .padding(.vertical, 10)
                        Divider().overlay(Color.dtLine)
                    }
                }
                .card().padding(16)
            }
            .background(AppBackground())
            .navigationTitle("Recent Activity").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
