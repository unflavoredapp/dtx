import Foundation

/// A recipe is a tool written as data. The server hands the app a small JSON file, and the app runs it with the steps below.
/// Nothing is downloaded as code, so recipes can come and go without an app update.
///
///   steps  (read things out of the IPA, each stored under a name):
///     { "op": "plist", "file": "Payload/*.app/Info.plist", "as": "info" }   unpack a property list
///     { "op": "text",  "file": "…", "as": "t" }                               unpack a text file
///     { "op": "glob",  "match": "Payload/*.app/Frameworks/*.dylib", "as": "dy" }   files whose path matches
///     { "op": "dirs",  "match": "Payload/*.app/PlugIns/*.appex", "as": "ext" }     folders whose path matches
///   output (what to show; {name.Key} fills in values, {n} is the row count, {opt.key} an option's value):
///     kv     { "title", "rows": [["Label", "{info.CFBundleName}"]] }          rows with an empty value are dropped
///     list   { "title", "from": "ext" | "info.UIBackgroundModes", "basename", "strip", "filter", "limit" }
///     table  { "title", "from": "info", "prefix": "NS", "suffix": "UsageDescription" }   or "rows": [[a, b]]
///     text   { "title", "from": "t" } or { "text": "…" }
struct Recipe: Decodable {
    struct Step: Decodable { var op: String; var file: String?; var match: String?; var `as`: String?; var optional: Bool? }
    struct Out: Decodable {
        var title: String?; var kind: String?; var rows: [[String]]?; var from: String?
        var prefix: String?; var suffix: String?; var strip: String?; var filter: String?
        var basename: Bool?; var limit: Int?; var text: String?
    }
    var id: String
    var name: String
    var summary: String?
    var icon: String?
    var mode: String?
    var version: String?
    var options: [PluginOption]?
    var steps: [Step]
    var output: [Out]
}

enum RecipeStore {
    private struct List: Decodable { var items: [Lossy<Recipe>]? }

    static func load() async -> [Tool] {
        guard let r: List = try? await Api.shared.get("/api/recipes") else { return [] }
        return (r.items ?? []).compactMap { $0.value }.map { rec in
            Tool(id: "recipe-" + rec.id, name: rec.name, summary: rec.summary ?? "", icon: rec.icon ?? "doc.text.magnifyingglass", origin: .recipe,
                 options: rec.options ?? [], auto: rec.mode == "background", version: rec.version ?? "", run: { ctx in try await RecipeRunner.run(rec, ctx) })
        }
    }
}

enum RecipeRunner {
    static func run(_ r: Recipe, _ ctx: ToolContext) async throws -> [PluginSection] {
        ctx.say("Opening the IPA's index…")
        let zip = try await RemoteZip.open(ctx.url)
        var plists: [String: [String: Any]] = [:], lists: [String: [String]] = [:], texts: [String: String] = [:]

        for s in r.steps.prefix(20) {
            try Task.checkCancellation()
            let name = s.as ?? ""
            switch s.op {
            case "plist", "text":
                guard let rx = regex(s.file ?? "") else { throw ZipError("Recipe \(r.name): a step has no file.") }
                guard let e = zip.entries.first(where: { !$0.isFolder && matches(rx, $0.name) }) else {
                    if s.optional == true { continue }
                    throw ZipError("This IPA has no \(s.file ?? "file") (needed by \(r.name)).")
                }
                ctx.say("Reading \((e.name as NSString).lastPathComponent)…")
                let d = try await zip.read(e)
                if s.op == "plist" {
                    guard let p = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any] else {
                        throw ZipError("\((e.name as NSString).lastPathComponent) isn't a property list.")
                    }
                    plists[name] = p
                } else { texts[name] = String(decoding: d, as: UTF8.self) }
            case "glob":
                guard let rx = regex(s.match ?? "") else { continue }
                lists[name] = zip.entries.filter { !$0.isFolder && matches(rx, $0.name) }.map(\.name)
            case "dirs":
                let pattern = s.match ?? ""
                guard let rx = regex(pattern) else { continue }
                let depth = pattern.split(separator: "/").count
                var seen = Set<String>()
                for e in zip.entries {
                    let parts = e.name.split(separator: "/")
                    guard parts.count >= depth else { continue }
                    let head = parts.prefix(depth).joined(separator: "/")
                    if matches(rx, head) { seen.insert(head) }
                }
                lists[name] = seen.sorted()
            default:
                throw ZipError("Recipe \(r.name) uses a step this app version doesn't know (\(s.op)). Update the app.")
            }
        }

        func lookup(_ path: String) -> String {
            if path == "n" { return "" }
            if path.hasPrefix("opt.") { return ctx.options[String(path.dropFirst(4))] ?? "" }
            let parts = path.split(separator: ".", maxSplits: 1).map(String.init)
            guard let head = parts.first else { return "" }
            let rest = parts.count > 1 ? parts[1] : nil
            if let list = lists[head] { return rest == "count" ? "\(list.count)" : list.joined(separator: ", ") }
            if let t = texts[head] { return rest == nil ? t : "" }
            if let p = plists[head] {
                guard let rest else { return "\(p.count)" }
                if rest.hasSuffix(".count"), let a = p[String(rest.dropLast(6))] as? [Any] { return "\(a.count)" }
                return BuiltinTools.text(p[rest])
            }
            return ""
        }
        func fill(_ t: String, n: Int? = nil) -> String {
            guard t.contains("{"), let rx = try? NSRegularExpression(pattern: "\\{([A-Za-z0-9_.\\-]+)\\}") else { return t }
            var out = t
            for m in rx.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
                guard let rr = Range(m.range, in: out), let kr = Range(m.range(at: 1), in: t) else { continue }
                let key = String(t[kr])
                out.replaceSubrange(rr, with: key == "n" ? "\(n ?? 0)" : lookup(key))
            }
            return out.trimmingCharacters(in: .whitespaces)
        }
        func listSource(_ from: String) -> [String] {
            if let l = lists[from] { return l }
            let parts = from.split(separator: ".", maxSplits: 1).map(String.init)
            if parts.count == 2, let a = plists[parts[0]]?[parts[1]] as? [Any] { return a.map { BuiltinTools.text($0) } }
            if parts.count == 2, let d = plists[parts[0]]?[parts[1]] as? [String: Any] { return d.keys.sorted() }
            return []
        }

        var out: [PluginSection] = []
        for o in r.output.prefix(30) {
            let kind = o.kind ?? "text"
            switch kind {
            case "kv":
                let rows = (o.rows ?? []).compactMap { row -> [String]? in
                    guard row.count >= 2 else { return nil }
                    let v = fill(row[1]); return v.isEmpty ? nil : [row[0], v]
                }
                if !rows.isEmpty { out.append(PluginSection(title: fill(o.title ?? "", n: rows.count), kind: "kv", rows: rows)) }
            case "list":
                var items = listSource(o.from ?? "")
                if o.basename == true { items = items.map { ($0 as NSString).lastPathComponent } }
                if let s = o.strip { items = items.map { $0.replacingOccurrences(of: s, with: "") } }
                let f = fill(o.filter ?? "").lowercased()
                if !f.isEmpty { items = items.filter { $0.lowercased().contains(f) } }
                if let l = o.limit { items = Array(items.prefix(max(0, min(l, 5000)))) }
                if !items.isEmpty { out.append(PluginSection(title: fill(o.title ?? "", n: items.count), kind: "list", items: items)) }
            case "table":
                var rows: [[String]] = (o.rows ?? []).map { $0.map { fill($0) } }
                if let from = o.from, let p = plists[from] {
                    for k in p.keys.sorted() where k.hasPrefix(o.prefix ?? "") && k.hasSuffix(o.suffix ?? "") {
                        var label = k
                        if let pre = o.prefix { label = String(label.dropFirst(pre.count)) }
                        if let suf = o.suffix { label = String(label.dropLast(suf.count)) }
                        rows.append([label.isEmpty ? k : label, BuiltinTools.text(p[k])])
                    }
                }
                if !rows.isEmpty { out.append(PluginSection(title: fill(o.title ?? "", n: rows.count), kind: "table", rows: rows)) }
            default:
                let t = o.text.map { fill($0) } ?? texts[o.from ?? ""] ?? ""
                if !t.isEmpty { out.append(PluginSection(title: fill(o.title ?? ""), kind: "text", text: t)) }
            }
        }
        return capped(out)
    }

    /// Whatever a recipe produces is trimmed before it reaches the screen: a bad or oversized recipe can't flood the UI.
    private static func capped(_ sections: [PluginSection]) -> [PluginSection] {
        func cut(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) : s }
        return sections.prefix(30).map { s in
            PluginSection(title: cut(s.title, 120), kind: s.kind,
                          rows: s.rows.prefix(1000).map { $0.prefix(10).map { cut($0, 500) } },
                          items: s.items.prefix(5000).map { cut($0, 500) }, cols: s.cols, text: cut(s.text, 200_000), note: cut(s.note, 300))
        }
    }

    /// `*` matches inside one folder level; nothing else is special.
    private static func regex(_ glob: String) -> NSRegularExpression? {
        guard !glob.isEmpty else { return nil }
        let esc = NSRegularExpression.escapedPattern(for: glob).replacingOccurrences(of: "\\*", with: "[^/]*")
        return try? NSRegularExpression(pattern: "^" + esc + "$")
    }
    private static func matches(_ rx: NSRegularExpression, _ s: String) -> Bool {
        rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
