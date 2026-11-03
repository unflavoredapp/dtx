import Foundation

/// The tools bundled with the app. They read the IPA straight from its link with range requests (no full download).
enum BuiltinTools {

    // MARK: App Info

    static let appInfo = Tool(
        id: "app-info", name: "App Info", summary: "Bundle ID, versions, permissions, URL schemes and more, read from the IPA's Info.plist.",
        icon: "info.circle.fill", origin: .bundled, auto: true, run: { ctx in
            ctx.say("Opening the IPA's index…")
            let zip = try await ZipSource.open(ctx)
            let (_, plist) = try await BuiltinTools.readPlist(zip, ctx)
            func s(_ k: String) -> String { BuiltinTools.text(plist[k]) }
            var kv: [[String]] = []
            func add(_ label: String, _ v: String) { if !v.isEmpty { kv.append([label, v]) } }
            add("Name", s("CFBundleDisplayName").isEmpty ? s("CFBundleName") : s("CFBundleDisplayName"))
            add("Bundle ID", s("CFBundleIdentifier"))
            add("Version", s("CFBundleShortVersionString"))
            add("Build", s("CFBundleVersion"))
            add("Executable", s("CFBundleExecutable"))
            add("Minimum iOS", s("MinimumOSVersion"))
            add("Built with", [s("DTPlatformName"), s("DTPlatformVersion")].filter { !$0.isEmpty }.joined(separator: " "))
            add("Xcode", s("DTXcode"))
            add("SDK", s("DTSDKName"))
            let fam = (plist["UIDeviceFamily"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }.map { BuiltinTools.family($0) }
            add("Devices", fam.joined(separator: ", "))
            add("Package size", ByteCountFormatter.string(fromByteCount: Int64(zip.total), countStyle: .file))
            var out = [PluginSection(title: "App", kind: "kv", rows: kv)]

            let schemes = (plist["CFBundleURLTypes"] as? [[String: Any]] ?? []).flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
            if !schemes.isEmpty { out.append(PluginSection(title: "URL schemes it answers to", kind: "list", items: schemes)) }
            let queried = plist["LSApplicationQueriesSchemes"] as? [String] ?? []
            if !queried.isEmpty { out.append(PluginSection(title: "Apps it checks for (\(queried.count))", kind: "list", items: queried)) }

            let perms = plist.keys.filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") }.sorted()
            if !perms.isEmpty {
                let rows = perms.map { k -> [String] in
                    var name = String(k.dropFirst(2).dropLast("UsageDescription".count))
                    if name.isEmpty { name = k }
                    return [name, BuiltinTools.text(plist[k])]
                }
                out.append(PluginSection(title: "Permissions it asks for (\(perms.count))", kind: "table", rows: rows))
            }
            let bg = plist["UIBackgroundModes"] as? [String] ?? []
            if !bg.isEmpty { out.append(PluginSection(title: "Background modes", kind: "list", items: bg)) }
            var caps = plist["UIRequiredDeviceCapabilities"] as? [String] ?? []
            if caps.isEmpty, let d = plist["UIRequiredDeviceCapabilities"] as? [String: Any] { caps = d.keys.sorted() }
            if !caps.isEmpty { out.append(PluginSection(title: "Required device features", kind: "list", items: caps)) }
            if let ats = plist["NSAppTransportSecurity"] as? [String: Any], !ats.isEmpty {
                out.append(PluginSection(title: "Network security (ATS)", kind: "kv", rows: ats.keys.sorted().map { [$0, BuiltinTools.text(ats[$0])] }))
            }
            return out
        })

    // MARK: Package Contents

    static let package = Tool(
        id: "package", name: "Package Contents", summary: "What's in the IPA: biggest files, frameworks, extensions, languages and signing leftovers.",
        icon: "shippingbox.fill", origin: .bundled, run: { ctx in
            ctx.say("Opening the IPA's index…")
            let zip = try await ZipSource.open(ctx)
            let files = zip.entries.filter { !$0.isFolder }
            let unpacked = files.reduce(Int64(0)) { $0 + $1.size }
            func fmt(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

            var frameworks: [String: Int64] = [:], dylibs: [String] = [], appex = Set<String>(), lproj = Set<String>()
            var hasSig = false, hasProfile = false, hasSC = false, hasWatch = false
            for e in files {
                let p = e.name.split(separator: "/").map(String.init)
                guard p.count >= 3, p[0] == "Payload" else { continue }
                let inner = Array(p.dropFirst(2))
                if inner[0] == "_CodeSignature" { hasSig = true }
                if inner[0] == "embedded.mobileprovision" { hasProfile = true }
                if inner[0] == "SC_Info" { hasSC = true }
                if inner[0] == "Watch" { hasWatch = true }
                if let x = inner.first(where: { $0.hasSuffix(".appex") }) { appex.insert(x); continue }
                if inner[0] == "Watch" { continue }
                if let l = inner.first(where: { $0.hasSuffix(".lproj") }) { lproj.insert(String(l.dropLast(".lproj".count))) }
                if inner.count >= 2, inner[0] == "Frameworks", inner[1].hasSuffix(".framework") { frameworks[inner[1], default: 0] += e.size }
                else if let last = inner.last, last.hasSuffix(".dylib") { dylibs.append(last) }
            }
            var out = [PluginSection(title: "Size", kind: "kv", rows: [
                ["IPA file", fmt(Int64(zip.total))], ["Unpacked", fmt(unpacked)], ["Files", "\(files.count)"],
            ])]
            let big = files.sorted { $0.size > $1.size }.prefix(10).map { e -> [String] in
                let parts = e.name.split(separator: "/").suffix(2).joined(separator: "/")
                return [parts, fmt(e.size)]
            }
            out.append(PluginSection(title: "Biggest files", kind: "table", rows: big))
            if !frameworks.isEmpty {
                out.append(PluginSection(title: "Frameworks (\(frameworks.count))", kind: "table", rows: frameworks.sorted { $0.value > $1.value }.map { [$0.key, fmt($0.value)] }))
            }
            if !dylibs.isEmpty { out.append(PluginSection(title: "Dylibs (\(dylibs.count))", kind: "list", items: dylibs.sorted())) }
            if !appex.isEmpty { out.append(PluginSection(title: "Extensions (\(appex.count))", kind: "list", items: appex.sorted())) }
            if !lproj.isEmpty {
                let names = lproj.sorted()
                out.append(PluginSection(title: "Languages (\(names.count))", kind: "text", text: names.prefix(60).joined(separator: ", ") + (names.count > 60 ? " …" : "")))
            }
            func yes(_ b: Bool) -> String { b ? "Yes" : "No" }
            out.append(PluginSection(title: "Signing and protection", kind: "kv", rows: [
                ["Code signature folder", yes(hasSig)], ["Embedded provisioning profile", yes(hasProfile)],
                ["App Store receipt data (SC_Info)", yes(hasSC)], ["Apple Watch app", yes(hasWatch)],
            ], note: "A decrypted IPA from the App Store usually keeps its code signature folder; a sideload-ready one often has its signature stripped."))
            return out
        })

    // MARK: Raw Info.plist

    static let rawPlist = Tool(
        id: "raw-plist", name: "Raw Info.plist", summary: "The IPA's full Info.plist as text, to copy.",
        icon: "doc.plaintext.fill", origin: .bundled, run: { ctx in
            ctx.say("Opening the IPA's index…")
            let zip = try await ZipSource.open(ctx)
            let (path, plist) = try await BuiltinTools.readPlist(zip, ctx)
            let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            return [PluginSection(title: path, kind: "text", text: String(decoding: xml, as: UTF8.self))]
        })

    // MARK: Link Check

    static let linkCheck = Tool(
        id: "link-check", name: "Link Check", summary: "Is the IPA link alive, how big is it, and can the app read it without downloading?",
        icon: "link.circle.fill", origin: .bundled, run: { ctx in
            if let local = ctx.localFile {
                let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int) ?? nil
                let bytes = size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "unknown"
                return [PluginSection(title: "Link", kind: "kv", rows: [
                    ["Source", "Attached in chat"], ["File", local.lastPathComponent], ["Size", bytes],
                ], note: "This file was attached directly, so there's no link to check — the app already has the whole thing.")]
            }
            ctx.say("Asking the server…")
            var r = URLRequest(url: ctx.url, timeoutInterval: 25)
            r.setValue("bytes=0-3", forHTTPHeaderField: "Range")
            let (data, resp) = try await URLSession.shared.data(for: r)
            guard let h = resp as? HTTPURLResponse else { throw ZipError("No answer from the server.") }
            func header(_ k: String) -> String { h.value(forHTTPHeaderField: k) ?? "" }
            var size = header("Content-Length")
            if let cr = h.value(forHTTPHeaderField: "Content-Range"), let slash = cr.lastIndex(of: "/") { size = String(cr[cr.index(after: slash)...]) }
            let bytes = Int64(size).map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown"
            let isZip = data.starts(with: [0x50, 0x4B])
            var rows: [[String]] = [
                ["Answer", "\(h.statusCode)"], ["Host", resp.url?.host ?? ctx.url.host ?? ""],
                ["Type", header("Content-Type")], ["Size", bytes],
                ["Looks like a zip / IPA", isZip ? "Yes" : "No"],
                ["Partial reads", h.statusCode == 206 ? "Yes (the app tools can scan it)" : "No (tools would need the whole file)"],
            ]
            if !header("Last-Modified").isEmpty { rows.append(["Last modified", header("Last-Modified")]) }
            if !header("ETag").isEmpty { rows.append(["ETag", header("ETag")]) }
            if let final = resp.url, final != ctx.url { rows.append(["Redirected to", final.absoluteString]) }
            return [PluginSection(title: "Link", kind: "kv", rows: rows)]
        })

    // MARK: helpers

    /// Finds Payload/<name>.app/Info.plist, unpacks it and reads it (binary or XML).
    static func readPlist(_ zip: AnyZip, _ ctx: ToolContext) async throws -> (String, [String: Any]) {
        guard let e = zip.entries.first(where: {
            let p = $0.name.split(separator: "/"); return p.count == 3 && p[0] == "Payload" && p[1].hasSuffix(".app") && p[2] == "Info.plist"
        }) else { throw ZipError("This IPA has no Payload/…app/Info.plist.") }
        ctx.say("Reading Info.plist…")
        let data = try await zip.read(e)
        guard let obj = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw ZipError("Info.plist isn't a normal property list.")
        }
        return (e.name, obj)
    }

    static func family(_ n: Int) -> String {
        switch n { case 1: return "iPhone"; case 2: return "iPad"; case 3: return "Apple TV"; case 4: return "Apple Watch"; case 7: return "Apple Vision"; default: return "Device \(n)" }
    }

    static func text(_ v: Any?) -> String {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        case let a as [Any]: return a.map { BuiltinTools.text($0) }.joined(separator: ", ")
        case let d as [String: Any]: return d.keys.sorted().map { "\($0): \(BuiltinTools.text(d[$0]))" }.joined(separator: ", ")
        case let d as Data: return "\(d.count) bytes"
        case let d as Date: return d.formatted()
        default: return ""
        }
    }
}
