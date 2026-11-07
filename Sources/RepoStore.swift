import CryptoKit
import Foundation
import SwiftUI

@MainActor
final class RepoStore: ObservableObject {
    static let defaultRepo = RepoInfo(url: "https://delvek.net/repo.json", name: "Delvek")
    private let key = "dt.repos"

    @Published var repos: [RepoInfo] = []
    @Published var apps: [AppEntry] = []
    @Published var meta: [String: RepoMeta] = [:]
    @Published var loading = false
    @Published var message: String?
    @Published var tab: AppTab = .home
    @Published var showQuickBuild = false
    /// Name handed to Decrypt from the Device tab ("DRM · Locked" apps).
    @Published var pendingDecryptQuery: String?
    // the search that drops down from the top bar
    let searcher = AppSearcher()
    @Published var searchOpen = false
    @Published var searchText = "" {
        didSet { if searchText != oldValue { searcher.update(query: searchText, apps: apps) } }
    }
    @Published var pickedApp: AppEntry?
    func closeSearch() { searchOpen = false; searchText = "" }
    @Published var showTools = false
    @Published var showAiDecrypt = false
    /// Bumped by the top buttons on list screens so the chat can open its sidebar / start a new chat when they close.
    /// The full-screen page currently open from the menu (nil = chat). Lives here so it survives theme refreshes.
    @Published var screen: AppScreen?
    @Published var hostDrawerTick = 0
    @Published var sidebarTick = 0
    @Published var newChatTick = 0

    @AppStorage("dt.server") var server: String = "https://decrypt.team"

    init() {
        searcher.minChars = 2
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([RepoInfo].self, from: data) {
            repos = list
        } else {
            repos = [Self.defaultRepo]          // until the person saves a list of their own
        }
    }

    var onlyDefault: Bool { repos.isEmpty || repos.allSatisfy { $0.url == Self.defaultRepo.url } }

    private func save() {
        if let data = try? JSONEncoder().encode(repos) { UserDefaults.standard.set(data, forKey: key) }
    }

    func refresh() async {
        loading = true; message = nil
        // Show the last list straight away (from disk) while the fresh copy downloads.
        if apps.isEmpty {
            let current = repos
            let cached: [AppEntry] = await Task.detached(priority: .userInitiated) {
                current.flatMap { r -> [AppEntry] in
                    guard let f = Self.cachedFile(r.url) else { return [] }
                    return Self.bundled(f.apps.map { Self.entry($0, repo: r, repoName: f.name ?? r.name) })
                }.sorted { $0.key < $1.key }
            }.value
            if !cached.isEmpty { apps = cached }
        }
        var all: [AppEntry] = []
        var names: [String: String] = [:]
        var metas: [String: RepoMeta] = [:]
        var failed = 0
        // Downloading, decoding and building the entries all happen off the main thread, so a huge repo doesn't freeze the app.
        await withTaskGroup(of: (RepoInfo, String?, [AppEntry]?, RepoMeta?).self) { group in
            for r in repos {
                group.addTask {
                    guard let file = try? await Self.fetch(r.url) else { return (r, nil, nil, nil) }
                    let n = file.name ?? r.name
                    let m = RepoMeta(icon: Self.https(file.iconURL),
                                     news: file.news.map { NewsItem(title: $0.title, caption: $0.caption ?? "", image: Self.https($0.imageURL), url: Self.https($0.url)) },
                                     featured: file.featured)
                    return (r, n, Self.bundled(file.apps.map { Self.entry($0, repo: r, repoName: n) }), m)
                }
            }
            for await (r, n, list, m) in group {
                guard let list, let n else { failed += 1; continue }
                names[r.url] = n
                if let m { metas[r.url] = m }
                all += list
            }
        }
        for i in repos.indices { if let n = names[repos[i].url], !n.isEmpty { repos[i].name = n } }
        save()
        meta = metas
        let merged = all
        apps = await Task.detached(priority: .userInitiated) { merged.sorted { $0.key < $1.key } }.value
        if failed > 0 { message = failed == 1 ? "One repo couldn't be loaded." : "\(failed) repos couldn't be loaded." }
        loading = false
        if !searchText.isEmpty { searcher.update(query: searchText, apps: apps) }
    }

    func add(_ text: String) async throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t), u.scheme == "https", u.host != nil else { throw RepoError.badURL }
        if repos.contains(where: { $0.url == t }) { return }
        let file = try await Self.fetch(t)
        // the default repo was only a starting point: adding your own list replaces the placeholder entry, never removes what you chose
        repos.insert(RepoInfo(url: t, name: file.name ?? u.host ?? "Repo"), at: 0)
        save()
        await refresh()
    }

    func remove(_ r: RepoInfo) {
        repos.removeAll { $0.url == r.url }
        save()
        apps.removeAll { $0.repoURL == r.url }
    }

    // MARK: network

    nonisolated static func fetch(_ urlString: String) async throws -> RepoFile {
        guard let url = URL(string: urlString), url.scheme == "https" else { throw RepoError.badURL }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw RepoError.http(h.statusCode) }
        guard data.count < 120_000_000 else { throw RepoError.notARepo }
        let file = try JSONDecoder().decode(RepoFile.self, from: data)
        try? data.write(to: cacheURL(urlString), options: .atomic)      // kept so the next launch can show apps instantly
        return file
    }

    nonisolated private static func cacheURL(_ repo: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("repo-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data(repo.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name + ".json")
    }

    nonisolated static func cachedFile(_ repo: String) -> RepoFile? {
        guard let d = try? Data(contentsOf: cacheURL(repo)) else { return nil }
        return try? JSONDecoder().decode(RepoFile.self, from: d)
    }

    nonisolated static func entry(_ a: RepoApp, repo: RepoInfo, repoName: String) -> AppEntry {
        var vs: [AppVersion] = (a.versions ?? []).map {
            AppVersion(version: $0.version, date: $0.date ?? "", url: Self.https($0.downloadURL), size: $0.size ?? 0, minOS: $0.minOSVersion ?? "")
        }
        if let v = a.version, !v.isEmpty, !vs.contains(where: { $0.version == v }) {
            vs.append(AppVersion(version: v, date: a.versionDate ?? "", url: Self.https(a.downloadURL), size: a.size ?? 0, minOS: ""))
        }
        vs.sort { compareVersions($0.version, $1.version) > 0 }
        return AppEntry(name: a.name, bid: a.bundleIdentifier, developer: a.developerName ?? "",
                        icon: Self.https(a.iconURL), versions: vs, repoName: repoName, repoURL: repo.url,
                        subtitle: a.subtitle ?? "", category: (a.category ?? "").trimmingCharacters(in: .whitespaces),
                        shots: a.shots.compactMap { Self.https($0) },
                        key: (a.name + "\n" + a.bundleIdentifier + "\n" + (a.developerName ?? "")).lowercased())
    }

    /// One entry per bundle ID: the same app listed several times (once per version, say) becomes a single app with all its versions.
    nonisolated static func bundled(_ list: [AppEntry]) -> [AppEntry] {
        var order: [String] = []
        var groups: [String: [AppEntry]] = [:]
        for a in list {
            if groups[a.bid] == nil { order.append(a.bid) }
            groups[a.bid, default: []].append(a)
        }
        return order.compactMap { bid -> AppEntry? in
            guard let g = groups[bid], let first = g.first else { return nil }
            if g.count == 1 && Set(first.versions.map { $0.version }).count == first.versions.count { return first }
            var seen = Set<String>()
            var vs: [AppVersion] = []
            for v in g.flatMap({ $0.versions }) where seen.insert(v.version).inserted { vs.append(v) }
            vs.sort { compareVersions($0.version, $1.version) > 0 }
            // describe the app by its newest listing
            let lead = g.first { $0.current?.version == vs.first?.version } ?? first
            return AppEntry(name: lead.name, bid: bid, developer: lead.developer.isEmpty ? first.developer : lead.developer,
                            icon: lead.icon ?? g.compactMap { $0.icon }.first, versions: vs, repoName: first.repoName, repoURL: first.repoURL,
                            subtitle: lead.subtitle.isEmpty ? (g.first { !$0.subtitle.isEmpty }?.subtitle ?? "") : lead.subtitle,
                            category: lead.category.isEmpty ? (g.first { !$0.category.isEmpty }?.category ?? "") : lead.category,
                            shots: lead.shots.isEmpty ? (g.first { !$0.shots.isEmpty }?.shots ?? []) : lead.shots,
                            key: lead.key)
        }
    }

    nonisolated static func https(_ s: String?) -> URL? {
        guard let s, let u = URL(string: s), u.scheme == "https" else { return nil }
        return u
    }
}


/// Every page the menu can open, shown full screen.
enum AppScreen: String, Identifiable {
    case browse, library, signed, signer, decrypt, certificate, batch, theme, install, tools, settings
    var id: String { rawValue }
}
