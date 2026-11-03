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
                    return (r, n, file.apps.map { Self.entry($0, repo: r, repoName: n) }, m)
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
        return try JSONDecoder().decode(RepoFile.self, from: data)
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

    nonisolated static func https(_ s: String?) -> URL? {
        guard let s, let u = URL(string: s), u.scheme == "https" else { return nil }
        return u
    }
}
