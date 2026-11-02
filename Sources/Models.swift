import Foundation

// MARK: - Lenient decoding (repo files differ a lot; one bad entry must not break the whole repo)

struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension KeyedDecodingContainer {
    func flexString(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let n = try? decodeIfPresent(Int64.self, forKey: key) { return String(n) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(d) }
        return nil
    }
    func flexInt(_ key: Key) -> Int64? {
        if let n = try? decodeIfPresent(Int64.self, forKey: key) { return n }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int64(d) }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int64(s) }
        return nil
    }
}

// MARK: - AltStore / SideStore style repo file

/// Screenshots come in several shapes: a list of links, a list of {imageURL}, or {iphone:[…], ipad:[…]}.
struct ShotList: Decodable {
    var urls: [String] = []
    private struct Obj: Decodable { var imageURL: String?; var url: String? }
    private struct Item: Decodable {
        var value: String
        init(from d: Decoder) throws {
            if let s = try? d.singleValueContainer().decode(String.self) { value = s; return }
            let o = try Obj(from: d)
            guard let v = o.imageURL ?? o.url else { throw RepoError.notARepo }
            value = v
        }
    }
    private struct Devices: Decodable { var iphone: [Lossy<Item>]?; var ipad: [Lossy<Item>]? }
    init(from decoder: Decoder) throws {
        if let arr = try? [Lossy<Item>](from: decoder) { urls = arr.compactMap { $0.value?.value }; return }
        if let dev = try? Devices(from: decoder) {
            urls = ((dev.iphone ?? []) + (dev.ipad ?? [])).compactMap { $0.value?.value }
        }
    }
}

struct RepoNews: Decodable {
    var title: String
    var caption: String?
    var imageURL: String?
    var url: String?
    enum CodingKeys: String, CodingKey { case title, caption, imageURL, url }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let t = c.flexString(.title) else { throw RepoError.notARepo }
        title = t; caption = c.flexString(.caption); imageURL = c.flexString(.imageURL); url = c.flexString(.url)
    }
}

struct RepoFile: Decodable {
    var name: String?
    var iconURL: String?
    var apps: [RepoApp]
    var news: [RepoNews]
    var featured: [String]

    enum CodingKeys: String, CodingKey { case name, iconURL, apps, news, featuredApps }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.flexString(.name)
        iconURL = c.flexString(.iconURL)
        news = (try? c.decodeIfPresent([Lossy<RepoNews>].self, forKey: .news))?.compactMap { $0.value } ?? []
        featured = (try? c.decodeIfPresent([String].self, forKey: .featuredApps)) ?? []
        guard let list = try? c.decode([Lossy<RepoApp>].self, forKey: .apps) else {
            throw RepoError.notARepo
        }
        apps = list.compactMap { $0.value }
    }
}

struct RepoApp: Decodable {
    var name: String
    var bundleIdentifier: String
    var developerName: String?
    var iconURL: String?
    var version: String?
    var versionDate: String?
    var downloadURL: String?
    var size: Int64?
    var versions: [RepoVersion]?
    var subtitle: String?
    var category: String?
    var shots: [String] = []

    enum CodingKeys: String, CodingKey {
        case name, bundleIdentifier, developerName, iconURL, version, versionDate, downloadURL, size, versions
        case subtitle, category, localizedDescription, screenshots, screenshotURLs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let bid = c.flexString(.bundleIdentifier), !bid.isEmpty else { throw RepoError.notARepo }
        bundleIdentifier = bid
        name = c.flexString(.name) ?? bid
        developerName = c.flexString(.developerName)
        iconURL = c.flexString(.iconURL)
        version = c.flexString(.version)
        versionDate = c.flexString(.versionDate)
        downloadURL = c.flexString(.downloadURL)
        size = c.flexInt(.size)
        versions = (try? c.decodeIfPresent([Lossy<RepoVersion>].self, forKey: .versions))?.compactMap { $0.value }
        category = c.flexString(.category)
        var sub = c.flexString(.subtitle) ?? ""
        if sub.isEmpty, let d = c.flexString(.localizedDescription) {
            sub = String(d.replacingOccurrences(of: "\n", with: " ").prefix(120))
        }
        subtitle = sub.isEmpty ? nil : sub
        let a = (try? c.decodeIfPresent(ShotList.self, forKey: .screenshots))?.urls ?? []
        let b = (try? c.decodeIfPresent([String].self, forKey: .screenshotURLs)) ?? []
        shots = Array((a.isEmpty ? b : a).prefix(4))
    }
}

struct RepoVersion: Decodable {
    var version: String
    var date: String?
    var downloadURL: String?
    var size: Int64?
    var minOSVersion: String?

    enum CodingKeys: String, CodingKey { case version, date, downloadURL, size, minOSVersion }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let v = c.flexString(.version), !v.isEmpty else { throw RepoError.notARepo }
        version = v
        date = c.flexString(.date)
        downloadURL = c.flexString(.downloadURL)
        size = c.flexInt(.size)
        minOSVersion = c.flexString(.minOSVersion)
    }
}

enum RepoError: LocalizedError {
    case notARepo, badURL, http(Int)
    var errorDescription: String? {
        switch self {
        case .notARepo: return "That isn't an AltStore or SideStore style repo file."
        case .badURL: return "That isn't a valid https link."
        case .http(let n): return "The repo answered with error \(n)."
        }
    }
}

// MARK: - What the app shows

struct AppVersion: Identifiable, Hashable {
    var id: String { version }
    let version: String
    let date: String
    let url: URL?
    let size: Int64
    let minOS: String
}

struct AppEntry: Identifiable, Hashable {
    var id: String { repoURL + "|" + bid }
    let name: String
    let bid: String
    let developer: String
    let icon: URL?
    let versions: [AppVersion]
    let repoName: String
    let repoURL: String
    let subtitle: String
    let category: String
    let shots: [URL]
    /// Lower-cased name, bundle ID and developer, made once so searching 17,000 apps stays fast. Also the sort order.
    let key: String
    var current: AppVersion? { versions.first }
}

struct RepoInfo: Codable, Identifiable, Hashable {
    var id: String { url }
    var url: String
    var name: String
}

/// search = Library (every app in your sources), repos = Browse (the sources list), signed = what you built.
enum AppTab: Hashable { case home, search, repos, signed, settings }

func compareVersions(_ a: String, _ b: String) -> Int {
    func parts(_ s: String) -> [Int] { s.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 } }
    let x = parts(a), y = parts(b)
    for i in 0..<max(x.count, y.count) {
        let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
        if p != q { return p < q ? -1 : 1 }
    }
    return 0
}


/// What a source says about itself, beyond its apps.
struct NewsItem: Identifiable, Hashable {
    var id: String { title + (url?.absoluteString ?? "") }
    let title: String
    let caption: String
    let image: URL?
    let url: URL?
}

struct RepoMeta {
    var icon: URL?
    var news: [NewsItem] = []
    var featured: [String] = []
}
