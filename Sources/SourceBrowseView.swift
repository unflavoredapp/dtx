import SwiftUI

/// What you see after tapping a source: its news, category chips, featured apps, then every app with screenshots.
struct SourceBrowseView: View {
    @EnvironmentObject var store: RepoStore
    let repo: RepoInfo

    enum Order { case name, newest, size }
    @AppStorage("dt.browse.twoCols") private var twoCols = false

    @State private var apps: [AppEntry] = []
    struct Chip: Identifiable { let name: String; let count: Int; var id: String { name } }
    @State private var chips: [Chip] = []
    @State private var category: String?          // nil = ALL
    @State private var order = Order.name
    @State private var shown = 20

    private var meta: RepoMeta? { store.meta[repo.url] }

    private var list: [AppEntry] {
        var l = category.map { c in apps.filter { $0.category.caseInsensitiveCompare(c) == .orderedSame } } ?? apps
        switch order {
        case .newest: l.sort { ($0.current?.date ?? "") > ($1.current?.date ?? "") }
        case .size: l.sort { ($0.current?.size ?? 0) > ($1.current?.size ?? 0) }
        case .name: break
        }
        return l
    }

    private var featured: [AppEntry] {
        guard let ids = meta?.featured, !ids.isEmpty else { return [] }
        let set = Set(ids)
        return apps.filter { set.contains($0.bid) }
    }

    var body: some View {
        let shownList = list
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let news = meta?.news, !news.isEmpty { newsSection(news) }
                if chips.count > 1 { chipsSection }
                if !featured.isEmpty { featuredSection }
                if twoCols {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(shownList.prefix(shown)) { app in
                            NavigationLink(value: app) { BrowseAppCard(app: app) }.buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 6)
                } else {
                    ForEach(shownList.prefix(shown)) { app in
                        NavigationLink(value: app) { BrowseAppRow(app: app) }.buttonStyle(.plain)
                        Divider().overlay(Color.dtLine)
                    }
                }
                if shown < shownList.count { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16).onAppear { shown += 20 } }
                if apps.isEmpty { Text(store.loading ? "Loading…" : "No apps in this source.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40) }
            }
            .padding(.horizontal, 14).padding(.bottom, 24)
        }
        .background(AppBackground())
        .withTopBar(.repos, title: repo.name.uppercased(), strip: "\(formatCount(Int64(apps.count))) Apps",
                    actions: [.search, .menu("line.3.horizontal.decrease.circle", [
                        ((order == .newest ? "✓ " : "") + "Recently updated", { order = .newest }),
                        ((order == .name ? "✓ " : "") + "Name", { order = .name }),
                        ((order == .size ? "✓ " : "") + "Size", { order = .size }),
                        ((twoCols ? "" : "✓ ") + "List", { twoCols = false }),
                        ((twoCols ? "✓ " : "") + "Two columns", { twoCols = true }),
                        ("Refresh", { Task { await store.refresh() } }),
                        ("Open repo.json", { if let u = URL(string: repo.url) { UIApplication.shared.open(u) } }),
                    ])], back: "Browse", titleIcon: meta?.icon)
        .task(id: store.apps.count) { rebuild() }
        .onChange(of: category) { _ in shown = 20 }
        .onChange(of: order) { _ in shown = 20 }
    }

    private func rebuild() {
        let mine = store.apps.filter { $0.repoURL == repo.url }
        apps = mine
        var counts: [String: Int] = [:]
        for a in mine where !a.category.isEmpty { counts[a.category.uppercased(), default: 0] += 1 }
        chips = Array(counts.map { Chip(name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }.prefix(14))
    }

    // MARK: sections

    private func header(_ t: String, icon: String? = nil) -> some View {
        HStack(spacing: 10) {
            if let icon { Image(systemName: icon).font(.system(size: 24)).foregroundStyle(Color.dtAccent) }
            Text(t).font(.system(size: 24, weight: .heavy)).tracking(4).foregroundStyle(.secondary)
        }
        .padding(.top, 20).padding(.bottom, 10).padding(.leading, 4)
    }

    private func newsSection(_ news: [NewsItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header("NEWS")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(news) { n in
                        Button { if let u = n.url { UIApplication.shared.open(u) } } label: {
                            ZStack(alignment: .bottomLeading) {
                                AsyncImage(url: n.image) { p in
                                    if let img = p.image { img.resizable().scaledToFill() } else { Color.white.opacity(0.05) }
                                }
                                .frame(width: 300, height: 240).clipped()
                                LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .center, endPoint: .bottom)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(n.title).font(.system(size: 22, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                                    if !n.caption.isEmpty { Text(n.caption).font(.system(size: 16)).foregroundStyle(.white.opacity(0.85)).lineLimit(2) }
                                }
                                .padding(14)
                            }
                            .frame(width: 300, height: 240).multilineTextAlignment(.leading)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.dtAccent.opacity(0.6), lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var chipsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: [GridItem(.fixed(50), spacing: 10), GridItem(.fixed(50), spacing: 10)], spacing: 10) {
                chip("ALL", apps.count, "square.grid.2x2.fill", on: category == nil) { category = nil }
                ForEach(chips) { c in
                    chip(c.name, c.count, Self.icon(c.name), on: category?.uppercased() == c.name) { category = (category?.uppercased() == c.name) ? nil : c.name }
                }
            }
            .padding(.vertical, 16)
        }
    }

    private func chip(_ name: String, _ count: Int, _ icon: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 17, weight: .bold))
                Text(name).font(.system(size: 18, weight: .heavy))
                Text("·").foregroundStyle(.secondary)
                Text(formatCount(Int64(count))).font(.system(size: 17, design: .monospaced)).foregroundStyle(.secondary)
            }
            .foregroundStyle(on ? Color.dtAccent : .white)
            .padding(.horizontal, 14).frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(on ? Color.dtAccent.opacity(0.14) : Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(on ? Color.dtAccent : Color.white.opacity(0.1), lineWidth: on ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    private static func icon(_ category: String) -> String {
        let c = category.lowercased()
        let table: [(String, String)] = [
            ("tool", "wrench.and.screwdriver.fill"), ("util", "wrench.and.screwdriver.fill"), ("paid", "dollarsign"),
            ("jail", "lock.open.fill"), ("media", "film.fill"), ("video", "film.fill"), ("music", "music.note"),
            ("social", "person.3.fill"), ("car", "car.fill"), ("emu", "gamecontroller.fill"), ("game", "gamecontroller.fill"),
            ("photo", "camera.fill"), ("develop", "chevron.left.forwardslash.chevron.right"), ("browser", "globe"),
            ("product", "checklist"), ("news", "newspaper.fill"), ("shop", "bag.fill"), ("travel", "airplane"),
        ]
        return table.first { c.contains($0.0) }?.1 ?? "square.grid.2x2.fill"
    }

    private var featuredSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("FEATURED", icon: "star.fill")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(featured) { app in
                        NavigationLink(value: app) {
                            HStack(alignment: .top, spacing: 14) {
                                AppIconView(url: app.icon, name: app.name, size: 80)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(app.name).font(.system(size: 24, weight: .bold)).foregroundStyle(Color.dtAccent).lineLimit(1)
                                    if !app.subtitle.isEmpty { Text(app.subtitle).font(.system(size: 17)).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading) }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(16).frame(width: 340, height: 130, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.dtAccent.opacity(0.10)))
                            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.dtAccent.opacity(0.55), lineWidth: 1.5))
                            .overlay(alignment: .topTrailing) { Image(systemName: "star.fill").foregroundStyle(Color.dtAccent).padding(14) }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.bottom, 10)
        }
    }
}

/// An app in a source: icon, name, "size | version | developer", its blurb and a strip of screenshots.
struct BrowseAppRow: View {
    let app: AppEntry

    private var line: String {
        var parts: [String] = []
        if let v = app.current {
            if v.size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: v.size, countStyle: .file)) }
            parts.append(v.version)
        }
        if !app.developer.isEmpty { parts.append(app.developer.uppercased()) }
        return parts.joined(separator: " | ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                AppIconView(url: app.icon, name: app.name, size: 66)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    if !line.isEmpty { Text(line).font(.system(size: 16)).foregroundStyle(.secondary).lineLimit(1) }
                    if !app.subtitle.isEmpty { Text(app.subtitle).font(.system(size: 16)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 17, weight: .bold)).foregroundStyle(.black)
                    .frame(width: 40, height: 40).background(Circle().fill(Color.dtAccent))
            }
            if !app.shots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(app.shots, id: \.self) { u in
                            AsyncImage(url: u) { p in
                                if let img = p.image { img.resizable().scaledToFill() } else { Color.white.opacity(0.06) }
                            }
                            .frame(width: 150, height: 300).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.1)))
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .padding(.vertical, 14).contentShape(Rectangle())
    }
}


/// The two-column card: icon and info button, name, bundle ID, then blurb and version.
struct BrowseAppCard: View {
    let app: AppEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                AppIconView(url: app.icon, name: app.name, size: 46)
                Spacer()
                Text("i").font(.system(size: 16, weight: .heavy, design: .serif)).foregroundStyle(Color.dtOnAccent)
                    .frame(width: 30, height: 30).background(Circle().fill(Color.dtAccent))
            }
            Text(app.name).font(.system(size: 15, weight: .bold)).foregroundStyle(Color.dtAccent).lineLimit(2).multilineTextAlignment(.leading)
            Text(app.bid).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 6) {
                Circle().stroke(Color.dtAccent, lineWidth: 2).frame(width: 9, height: 9)
                Text(app.subtitle.isEmpty ? app.developer : app.subtitle).font(.system(size: 12)).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 0)
                if let v = app.current?.version { Text(v).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Color.dtAccent).lineLimit(1) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.dtAccent.opacity(0.35), lineWidth: 1))
        .contentShape(Rectangle())
    }
}
