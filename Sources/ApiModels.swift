import Foundation

// MARK: - Home: stats and changelog

struct Stats: Decodable {
    struct Total: Decodable {
        var total: Int64
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            if let n = try? c.decode(Int64.self, forKey: .total) { total = n }
            else if let d = try? c.decode(Double.self, forKey: .total) { total = Int64(d) }
            else { total = 0 }
        }
        enum K: String, CodingKey { case total }
    }
    var decrypts: Total?
    var injections: Total?
    var visitors: Total?
    var day: Total?
    var now: Total?
}

struct ChangelogReply: Decodable {
    struct Entry: Decodable {
        var date: String
        var items: [String]
    }
    var entries: [Entry]?
}

// MARK: - App page

struct StoreInfo: Decodable {
    var id: String?
    var name: String?
    var ver: String?
    var minos: String?
    var icon: String?
    var updated: String?

    enum K: String, CodingKey { case id, name, ver, minos, icon, updated }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = c.flexString(.id); name = c.flexString(.name); ver = c.flexString(.ver)
        minos = c.flexString(.minos); icon = c.flexString(.icon); updated = c.flexString(.updated)
    }
}

struct UpstreamReply: Decodable {
    struct Item: Decodable {
        var store: StoreInfo?
        var library: [LibVersion]?
    }
    var items: [String: Item]?
}

struct LibVersion: Decodable, Identifiable {
    var id: String { (appId ?? "") + "|" + ver }
    var appId: String?
    var ver: String
    enum K: String, CodingKey { case appId, ver }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        appId = c.flexString(.appId)
        ver = c.flexString(.ver) ?? ""
    }
}

struct SetItem: Decodable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var type: String
    var size: Int64
    enum K: String, CodingKey { case name, type, size }
    init(name: String, type: String, size: Int64) { self.name = name; self.type = type; self.size = size }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        name = c.flexString(.name) ?? "?"
        type = c.flexString(.type) ?? (name.hasSuffix(".framework") ? "framework" : "dylib")
        size = c.flexInt(.size) ?? 0
    }
}

struct SavedSet: Decodable, Identifiable {
    var id: String
    var version: String
    var count: Int
    var items: [SetItem]
    enum K: String, CodingKey { case id, version, count, items }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = c.flexString(.id) ?? UUID().uuidString
        version = c.flexString(.version) ?? ""
        count = Int(c.flexInt(.count) ?? 0)
        items = (try? c.decodeIfPresent([Lossy<SetItem>].self, forKey: .items))?.compactMap { $0.value } ?? []
    }
}

struct SetsReply: Decodable { var sets: [SavedSet]? }

// MARK: - Tools (server plugins)

struct PluginOption: Decodable, Identifiable {
    var id: String { key }
    var key: String
    var label: String
    var type: String
    var def: String
    enum K: String, CodingKey { case key, label, type, def }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        key = c.flexString(.key) ?? ""
        label = c.flexString(.label) ?? key
        type = c.flexString(.type) ?? "text"
        def = (try? c.decodeIfPresent(Flex.self, forKey: .def))?.text ?? ""
    }
}

struct PluginInfo: Decodable, Identifiable {
    var id: String
    var name: String
    var description: String
    var options: [PluginOption]
    enum K: String, CodingKey { case id, name, description, options }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = c.flexString(.id) ?? ""
        name = c.flexString(.name) ?? id
        description = c.flexString(.description) ?? ""
        options = (try? c.decodeIfPresent([Lossy<PluginOption>].self, forKey: .options))?.compactMap { $0.value } ?? []
    }
}

struct PluginList: Decodable { var items: [PluginInfo]? }
struct PluginStart: Decodable { var id: String? }

struct PluginSection: Decodable, Identifiable {
    var id = UUID()
    var title: String
    var kind: String
    var rows: [[String]]
    var items: [String]
    var cols: [String]
    var text: String
    var note: String
    enum K: String, CodingKey { case title, kind, rows, items, cols, text, note }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        title = c.flexString(.title) ?? ""
        kind = c.flexString(.kind) ?? "text"
        rows = (try? c.decodeIfPresent([[String]].self, forKey: .rows)) ?? []
        items = (try? c.decodeIfPresent([String].self, forKey: .items)) ?? []
        cols = (try? c.decodeIfPresent([String].self, forKey: .cols)) ?? []
        text = c.flexString(.text) ?? ""
        note = c.flexString(.note) ?? ""
    }
}

struct PluginJob: Decodable {
    struct Result: Decodable { var sections: [PluginSection]? }
    var status: String?
    var msg: String?
    var pct: Int?
    var error: String?
    var result: Result?
}

// MARK: - Recent activity

struct RecentReply: Decodable {
    struct Item: Decodable, Identifiable {
        var name: String
        var ver: String
        var icon: String?
        var id: String { name + "|" + ver }
        enum K: String, CodingKey { case name, ver, icon }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            name = c.flexString(.name) ?? "App"; ver = c.flexString(.ver) ?? ""; icon = c.flexString(.icon)
        }
    }
    var items: [Item]?
}
