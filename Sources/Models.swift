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

struct RepoFile: Decodable {
    var name: String?
    var iconURL: String?
    var apps: [RepoApp]

    enum CodingKeys: String, CodingKey { case name, iconURL, apps }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.flexString(.name)
        iconURL = c.flexString(.iconURL)
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

    enum CodingKeys: String, CodingKey {
        case name, bundleIdentifier, developerName, iconURL, version, versionDate, downloadURL, size, versions
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
    /// Lower-cased name, bundle ID and developer, made once so searching 17,000 apps stays fast. Also the sort order.
    let key: String
    var current: AppVersion? { versions.first }
}

struct RepoInfo: Codable, Identifiable, Hashable {
    var id: String { url }
    var url: String
    var name: String
}

enum AppTab: Hashable { case home, search, repos, settings }

func compareVersions(_ a: String, _ b: String) -> Int {
    func parts(_ s: String) -> [Int] { s.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 } }
    let x = parts(a), y = parts(b)
    for i in 0..<max(x.count, y.count) {
        let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
        if p != q { return p < q ? -1 : 1 }
    }
    return 0
}
