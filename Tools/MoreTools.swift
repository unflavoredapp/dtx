import Foundation

/// Extra bundled tools. Same rules as BuiltinTools: read the IPA with range requests, never download the whole file.
enum MoreTools {

    private static func mainApp(_ zip: RemoteZip) -> String? {
        zip.entries.first { let p = $0.name.split(separator: "/"); return p.count == 2 && p[0] == "Payload" && p[1].hasSuffix(".app/") }?.name
            ?? zip.entries.compactMap { e -> String? in
                let p = e.name.split(separator: "/"); return p.count >= 2 && p[0] == "Payload" && p[1].hasSuffix(".app") ? "Payload/\(p[1])/" : nil
            }.first
    }

    // MARK: Binary Inspector

    static let binary = Tool(
        id: "binary", name: "Binary Inspector", summary: "Architectures, encryption state, minimum iOS, linked libraries and run paths of the main executable.",
        icon: "cpu.fill", origin: .bundled, run: { ctx in
            ctx.say("Opening the IPA's index…")
            let zip = try await RemoteZip.open(ctx.url)
            let (path, plist) = try await BuiltinTools.readPlist(zip, ctx)
            let exeName = BuiltinTools.text(plist["CFBundleExecutable"])
            let exePath = path.replacingOccurrences(of: "Info.plist", with: exeName)
            guard !exeName.isEmpty, let e = zip.entries.first(where: { $0.name == exePath }) else { throw ZipError("Couldn't find the main executable in this IPA.") }
            ctx.say("Reading the start of \(exeName)…")
            let head = try await zip.readPrefix(e, maxOut: 1_500_000)
            let slices = MachO.parse(head)
            guard !slices.isEmpty else { throw ZipError("\(exeName) isn't a program the app can read (not a 64-bit Mach-O).") }

            var out: [PluginSection] = []
            let size = ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file)
            var summary: [[String]] = [["Executable", exeName], ["Size", size], ["Architectures", slices.map(\.cpu).joined(separator: ", ")]]
            let verdicts = slices.compactMap { s -> String? in
                guard s.parsed else { return nil }
                guard let enc = s.encrypted else { return "\(s.cpu): no encryption info" }
                return "\(s.cpu): " + (enc ? "ENCRYPTED (FairPlay)" : "decrypted")
            }
            if !verdicts.isEmpty { summary.append(["Encryption", verdicts.joined(separator: "  ·  ")]) }
            out.append(PluginSection(title: "Binary", kind: "kv", rows: summary))

            for s in slices where s.parsed {
                var rows: [[String]] = []
                if !s.minOS.isEmpty { rows.append(["Minimum iOS", s.minOS]) }
                if !s.sdk.isEmpty { rows.append(["Built with SDK", s.sdk]) }
                if !s.uuid.isEmpty { rows.append(["UUID", s.uuid]) }
                rows.append(["Code signature", s.signed ? "present" : "none"])
                out.append(PluginSection(title: "Details · \(s.cpu)", kind: "kv", rows: rows))
            }
            if let s = slices.first(where: { $0.parsed }) {
                let libs = s.libs.sorted()
                let system = libs.filter { $0.hasPrefix("/usr/lib") || $0.hasPrefix("/System") }
                let bundled = libs.filter { !system.contains($0) }
                if !bundled.isEmpty { out.append(PluginSection(title: "Libraries inside the app (\(bundled.count))", kind: "list", items: bundled)) }
                if !system.isEmpty { out.append(PluginSection(title: "System libraries (\(system.count))", kind: "list", items: system.map { ($0 as NSString).lastPathComponent })) }
                if !s.rpaths.isEmpty { out.append(PluginSection(title: "Run paths", kind: "list", items: s.rpaths)) }
            }
            if slices.contains(where: { !$0.parsed }) {
                out.append(PluginSection(title: "Note", kind: "text", text: "One architecture sits further into the file than the app reads, so only its CPU type is shown."))
            }
            return out
        })

    // MARK: Embedded Bundles

    static let bundles = Tool(
        id: "bundles", name: "Embedded Bundles", summary: "Every framework, extension and plug-in inside the app, with its bundle ID and version.",
        icon: "square.stack.3d.up.fill", origin: .bundled, run: { ctx in
            ctx.say("Opening the IPA's index…")
            let zip = try await RemoteZip.open(ctx.url)
            guard let root = mainApp(zip) else { throw ZipError("This IPA has no Payload/…app folder.") }
            let infos = zip.entries.filter {
                guard !$0.isFolder, $0.name.hasPrefix(root), $0.name.hasSuffix("/Info.plist") else { return false }
                let rest = $0.name.dropFirst(root.count)
                return rest.contains(".framework/") || rest.contains(".appex/") || rest.contains(".app/")   // skip the main plist and resource plists
            }.filter { e in
                let rest = String(e.name.dropFirst(root.count)).split(separator: "/").map(String.init)
                // keep only the bundle's own Info.plist: <anything>.<ext>/Info.plist
                return rest.count >= 2 && (rest[rest.count - 2].hasSuffix(".framework") || rest[rest.count - 2].hasSuffix(".appex") || rest[rest.count - 2].hasSuffix(".app"))
            }
            guard !infos.isEmpty else { return [PluginSection(title: "Embedded bundles", kind: "text", text: "This IPA has no frameworks or extensions inside it.")] }
            var rows: [[String]] = []
            for (i, e) in infos.prefix(60).enumerated() {
                ctx.say("Reading \(i + 1) of \(min(infos.count, 60))…")
                let folder = String(e.name.dropFirst(root.count).dropLast("/Info.plist".count))
                let name = (folder as NSString).lastPathComponent
                if let d = try? await zip.read(e, limit: 200_000),
                   let p = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any] {
                    let ver = BuiltinTools.text(p["CFBundleShortVersionString"])
                    rows.append([name, [BuiltinTools.text(p["CFBundleIdentifier"]), ver.isEmpty ? "" : "v" + ver].filter { !$0.isEmpty }.joined(separator: " · ")])
                } else { rows.append([name, "couldn't read"]) }
            }
            var out = [PluginSection(title: "Embedded bundles (\(infos.count))", kind: "table", rows: rows)]
            if infos.count > 60 { out.append(PluginSection(title: "Note", kind: "text", text: "Showing the first 60 of \(infos.count).")) }
            return out
        })

    // MARK: Privacy Manifest

    static let privacy = Tool(
        id: "privacy", name: "Privacy Manifest", summary: "What the app declares in PrivacyInfo.xcprivacy: tracking, data it collects, reasons for sensitive APIs.",
        icon: "hand.raised.fill", origin: .bundled, run: { ctx in
            ctx.say("Opening the IPA's index…")
            let zip = try await RemoteZip.open(ctx.url)
            guard let root = mainApp(zip) else { throw ZipError("This IPA has no Payload/…app folder.") }
            guard let e = zip.entries.first(where: { $0.name == root + "PrivacyInfo.xcprivacy" }) else {
                return [PluginSection(title: "Privacy manifest", kind: "text", text: "This app doesn't ship a privacy manifest (PrivacyInfo.xcprivacy). Older builds usually don't.")]
            }
            let data = try await zip.read(e)
            guard let p = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { throw ZipError("The manifest isn't readable.") }
            var out: [PluginSection] = []
            let tracking = (p["NSPrivacyTracking"] as? Bool) == true
            var kv: [[String]] = [["Tracks you", tracking ? "Yes" : "No"]]
            let domains = p["NSPrivacyTrackingDomains"] as? [String] ?? []
            if !domains.isEmpty { kv.append(["Tracking domains", "\(domains.count)"]) }
            out.append(PluginSection(title: "Declaration", kind: "kv", rows: kv))
            if !domains.isEmpty { out.append(PluginSection(title: "Tracking domains", kind: "list", items: domains)) }
            let collected = (p["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? []).compactMap { $0["NSPrivacyCollectedDataType"] as? String }
                .map { $0.replacingOccurrences(of: "NSPrivacyCollectedDataType", with: "") }
            if !collected.isEmpty { out.append(PluginSection(title: "Data it collects (\(collected.count))", kind: "list", items: collected)) }
            let api = (p["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []).map { d -> [String] in
                let t = (d["NSPrivacyAccessedAPIType"] as? String ?? "").replacingOccurrences(of: "NSPrivacyAccessedAPICategory", with: "")
                let r = (d["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []).joined(separator: ", ")
                return [t, r]
            }
            if !api.isEmpty { out.append(PluginSection(title: "Sensitive APIs it uses (\(api.count))", kind: "table", rows: api)) }
            return out
        })
}
