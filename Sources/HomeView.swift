import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: RepoStore
    @EnvironmentObject var session: Session
    @State private var query = ""
    @State private var stats: Stats?
    @State private var entry: ChangelogReply.Entry?
    @State private var page: IdentifiedURL?
    @FocusState private var focus: Bool

    private var results: [AppEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        return store.apps.filter { $0.name.lowercased().contains(q) || $0.bid.lowercased().contains(q) || $0.developer.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    tools
                    searchBar
                    if store.onlyDefault { repoNotice }
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        HStack(alignment: .top, spacing: 12) {
                            changelogCard
                            statsCard
                        }
                    } else {
                        resultsList
                    }
                    footer
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .background(Color.dtBG)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: AppEntry.self) { AppDetailView(app: $0) }
            .task { await load() }
            .refreshable { await load(); await store.refresh() }
            .sheet(item: $page) { SafariSheet(url: $0.url).ignoresSafeArea() }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Image("Logo").resizable().frame(width: 42, height: 42).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                (Text("Decrypt.").foregroundColor(.white) + Text("team").foregroundColor(.dtAccent)).font(.title3.bold())
                Text("iOS app discovery and decryption tools").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            Button {
                if session.signedIn { session.showLogin = true } else { session.showLogin = true }
            } label: {
                VStack(alignment: .trailing, spacing: 1) {
                    Label(session.username ?? "Sign in", systemImage: "person").font(.subheadline.weight(.semibold)).foregroundStyle(Color.dtAccent)
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: featured tools

    private var tools: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Featured Tools").font(.title3.bold())
                Spacer()
                Button("See all ›") { open("/tools") }.font(.subheadline.weight(.semibold)).foregroundStyle(Color.dtAccent)
            }
            HStack(spacing: 10) {
                toolCard("App requests", "Request any app or tweak", "square.and.pencil", [.blue, .cyan], nil, "/requests")
                toolCard("Decrypt Dylib", "Our dylib decrypt reconstruction", "lock.open.fill", [.orange, .red], "EXCLUSIVE", "/dylib")
                toolCard("Updates", "Check for the latest app versions", "arrow.triangle.2.circlepath", [.blue, .indigo], nil, "/changelog")
            }
        }
    }

    private func toolCard(_ title: String, _ sub: String, _ icon: String, _ colors: [Color], _ badge: String?, _ path: String) -> some View {
        Button { open(path) } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(title).font(.subheadline.bold()).foregroundStyle(.white).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
                Text(sub).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
                if let badge { Text(badge).font(.system(size: 9, weight: .bold)).foregroundStyle(Color.dtAccent).padding(.horizontal, 6).padding(.vertical, 2).overlay(Capsule().stroke(Color.dtAccent)) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .top)
            .padding(.vertical, 12).padding(.horizontal, 6)
            .background(Color.dtCard)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.dtLine))
        }
        .buttonStyle(.plain)
    }

    private func open(_ path: String) {
        if let u = URL(string: Api.shared.base + path) { page = IdentifiedURL(url: u) }
    }

    // MARK: search

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search apps in your repos", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search).focused($focus)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Color.dtCard)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(focus ? Color.dtAccent : Color.dtLine, lineWidth: focus ? 2 : 1))
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
        VStack(spacing: 0) {
            if results.isEmpty {
                Text(query.trimmingCharacters(in: .whitespaces).count < 2 ? "Type an app name to search your repos." : "No apps found in your repos.")
                    .foregroundStyle(.secondary).padding(.vertical, 30)
            }
            ForEach(results) { app in
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
                if app.id != results.last?.id { Divider().overlay(Color.dtLine) }
            }
        }
        .card()
    }

    // MARK: changelog and stats

    private func split(_ s: String) -> (String, String) {
        if let r = s.range(of: #"^(.{12,70}?[.:])\s+(.+)$"#, options: .regularExpression) {
            let whole = String(s[r])
            if let cut = whole.firstIndex(where: { $0 == "." || $0 == ":" }) {
                let title = String(whole[..<cut]); let rest = String(whole[whole.index(after: cut)...]).trimmingCharacters(in: .whitespaces)
                if title.count >= 12 { return (title, rest) }
            }
        }
        return (s, "")
    }

    private var changelogCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Changelog", systemImage: "doc.text").font(.headline).foregroundStyle(.white)
            if let e = entry {
                HStack(spacing: 6) {
                    Pill(text: "NEW", tone: .dtGreen)
                    Text(e.date).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(e.items.prefix(4).enumerated()), id: \.offset) { _, item in
                    let (t, d) = split(item)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t).font(.subheadline.bold()).foregroundStyle(.white).lineLimit(2)
                        if !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Divider().overlay(Color.dtLine)
                }
                Button { open("/changelog") } label: {
                    Label("View Full Changelog", systemImage: "doc.text").font(.subheadline.weight(.semibold)).foregroundStyle(Color.dtAccent)
                }
            } else {
                Text("Nothing here yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }

    private func stat(_ icon: String, _ n: Int64?, _ label: String, _ tone: Color = .dtAccent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tone).frame(width: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(n.map { formatCount($0) } ?? "–").font(.headline).foregroundStyle(.white)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(tone == .dtGreen ? tone.opacity(0.7) : Color.dtLine))
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Stats", systemImage: "chart.bar").font(.headline).foregroundStyle(.white)
                Spacer(minLength: 2)
                Pill(text: "LIVE", tone: .dtGreen)
            }
            stat("lock", stats?.decrypts?.total, "Total Decrypts")
            stat("square.stack.3d.up", stats?.injections?.total, "Dylib Injections")
            stat("person.2", stats?.visitors?.total, "Total Visitors")
            stat("calendar", stats?.day?.total, "Visitors (24h)")
            stat("person.2.wave.2", stats?.now?.total, "Online Now", .dtGreen)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text("BUILT BY").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
            (Text("The ").foregroundColor(.white) + Text("Decrypt.team").foregroundColor(.dtAccent) + Text(" Team").foregroundColor(.white)).font(.subheadline.bold())
            Text("Special thanks to everyone who helps make this possible.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private func load() async {
        async let s: Stats? = try? Api.shared.get("/api/stats")
        async let c: ChangelogReply? = try? Api.shared.get("/api/changelog")
        stats = await s
        entry = await c?.entries?.first
    }
}
