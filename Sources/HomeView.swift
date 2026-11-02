import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: RepoStore
    @EnvironmentObject var session: Session
    @State private var stats: Stats?
    @State private var changes: [ChangelogReply.Entry] = []
    @State private var recent: [RecentReply.Item] = []
    @State private var showChangelog = false
    @State private var showActivity = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    tools
                    if store.onlyDefault { repoNotice }
                    statsRow
                    changelogCard
                    activityCard
                    footer
                }
                .padding(.horizontal, 14).padding(.bottom, 120)
            }
            .background(AppBackground())
            .withTopBar(.home)
            .navigationDestination(for: AppEntry.self) { AppDetailView(app: $0) }
            .task { await load() }
            .refreshable { await load(); await store.refresh() }
            .sheet(isPresented: $showChangelog) { ChangelogView() }
            .sheet(isPresented: $showActivity) { ActivityView(items: recent) }
        }
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
                toolCard("Decrypt & Inject", nil, "lock.open.fill", [Color(red: 0.99, green: 0.55, blue: 0.2), .red], "EXCLUSIVE") { store.showQuickBuild = true }
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
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.065)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    // MARK: notice

    private var repoNotice: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.repos.isEmpty ? "No repos added" : "Searching the Delvek repo").font(.subheadline.bold())
                Text(store.repos.isEmpty ? "Add a repo to search for apps." : "Add your own repo to find more apps.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add a repo") { store.tab = .repos }.buttonStyle(AccentButtonStyle())
        }
        .padding(12)
        .background(Color.dtAccent.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.dtAccent))
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
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.8)
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .aspectRatio(1, contentMode: .fit)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.065)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.1)))
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
        VStack(spacing: 14) {
            Divider().overlay(Color.white.opacity(0.12))
            HStack(alignment: .center, spacing: 12) {
                Image("Logo").resizable().frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("BUILT BY").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                    (Text("The ").foregroundColor(.white) + Text("Decrypt.team").foregroundColor(.dtAccent)).font(.subheadline.bold())
                    Text("Special thanks to everyone who helps make this possible.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Divider().overlay(Color.white.opacity(0.12))
            VStack(alignment: .leading, spacing: 10) {
                Text("TEAM").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 8) {
                    member("MRZEFA", "Developer")
                    member("Oxcffaedfe", "Developer")
                    member("DELvEK", "Repository")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 6)
    }

    private func member(_ name: String, _ role: String) -> some View {
        VStack(spacing: 4) {
            Text(String(name.prefix(1)))
                .font(.system(size: 22, weight: .heavy)).foregroundStyle(.black)
                .frame(width: 52, height: 52).background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.dtAccent))
            Text(name).font(.footnote.weight(.bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
            Text(role).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
