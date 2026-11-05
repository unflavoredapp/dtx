import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model: Decrypt (if needed) → build on the server → hand over the link or the file

struct FrameworkFile: Hashable {
    let rel: String      // path inside the .framework folder
    let data: Data
}

/// A library the person added: one .dylib, or a whole .framework folder.
struct PickedLib: Identifiable, Hashable {
    var id: String { name }
    let name: String
    var data = Data()                  // a .dylib
    var exec: String? = nil            // a .framework: the path of its binary inside the folder
    var files: [FrameworkFile] = []    // a .framework: every file in it
    var isFramework: Bool { exec != nil }
    var size: Int64 { isFramework ? files.reduce(0) { $0 + Int64($1.data.count) } : Int64(data.count) }
}

enum BuildSource: Hashable {
    case repo(URL, version: String)
    case store(id: String, version: String)
    var version: String { switch self { case .repo(_, let v): return v; case .store(_, let v): return v } }
}

struct BuildOptions {
    var rpath = false          // false: @executable_path, true: @rpath
    var frameworksFolder = true
    var stripSignature = true
    var name = ""              // optional edits to the app's own info
    var bid = ""
    var minOS = ""
    var remove: [String] = []  // load commands to strip from the main binary
}

enum BuildStage: Equatable { case idle, decrypting, uploading, building, done, failed }

@MainActor
final class BuildModel: ObservableObject {
    @Published var stage: BuildStage = .idle
    @Published var message = ""
    @Published var pct = 0.0
    @Published var queue = 0
    @Published var error = ""
    @Published var errorLog: URL?
    @Published var running = false
    // the finished build
    @Published var outName = ""
    @Published var outSize: Int64 = 0
    @Published var outSha = ""
    @Published var outLink: URL?
    @Published var added: [String] = []
    // downloading it to the phone
    @Published var downloading = false
    @Published var downloadPct = 0.0
    @Published var localFile: URL?
    @Published var downloadError = ""

    private(set) var jobID = ""
    private var task: Task<Void, Never>?

    func reset() { stage = .idle; error = ""; errorLog = nil; message = ""; pct = 0; localFile = nil; downloadError = "" }

    func start(app: AppEntry, source: BuildSource, options: BuildOptions, libs: [PickedLib]) {
        reset(); running = true
        task = Task { [weak self] in
            guard let self else { return }
            do { try await self.run(app, source, options, libs) }
            catch is CancellationError { self.stage = .failed; self.error = "Cancelled." }
            catch { await self.fail(error) }
            self.running = false
        }
    }

    func cancel() {
        task?.cancel()
        let id = jobID
        if !id.isEmpty { Task { _ = try? await Api.shared.request("POST", "/api/build/\(id)/cancel", json: [String: Any]()) } }
        running = false; stage = .failed; error = "Cancelled."
    }

    /// Frees a build left running on the account (a 409 "already running" means the last one wasn't finished).
    func cancelStale() async {
        struct Active: Decodable { struct J: Decodable { var id: String }; var job: J? }
        if let a: Active = try? await Api.shared.get("/api/build/active"), let j = a.job {
            _ = try? await Api.shared.request("POST", "/api/build/\(j.id)/cancel", json: [String: Any]())
            error = "The earlier build was told to stop. Wait a few seconds, then build again."
        }
    }

    // MARK: the steps

    private struct Started: Decodable { var id: String; var chunk: Int? }
    private struct DecStart: Decodable { var id: String }
    private struct DecState: Decodable { var status: String; var msg: String?; var error: String?; var up: String?; var queue: Int? }
    private struct Out: Decodable { var url: String?; var fname: String?; var size: Int64?; var sha256: String?; var added: Int?; var loads: [Load]? }
    private struct Load: Decodable { var name: String? }
    private struct JobState: Decodable { var status: String; var msg: String?; var pct: Int?; var queue: Int?; var error: String?; var out: Out? }

    private func run(_ app: AppEntry, _ source: BuildSource, _ o: BuildOptions, _ libs: [PickedLib]) async throws {
        // 1. where the IPA comes from
        var src: [String: Any] = [:]
        switch source {
        case .repo(let url, _):
            src = ["url": url.absoluteString]
        case .store(let id, let version):
            stage = .decrypting; message = "Starting the decrypt…"
            var body: [String: Any] = ["url": "https://apps.apple.com/app/id" + id]
            if !version.isEmpty { body["version"] = version }
            let d: DecStart = try await Api.shared.post("/api/decrypt", json: body)
            var misses = 0
            while true {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 2_000_000_000)
                do {
                    let s: DecState = try await Api.shared.get("/api/decrypt/" + d.id); misses = 0
                    if s.status == "error" { throw ApiError.server(s.error ?? "The decrypt failed.", 0) }
                    if s.status == "done", let up = s.up { src = ["up": up]; break }
                    message = s.msg ?? "Decrypting on the server…"; queue = s.queue ?? 0
                } catch let e as ApiError where e.status == 0 { throw e }
                catch { misses += 1; if misses > 30 { throw error } }
            }
        }

        // 2. the build: settings, own libraries, then the job
        var libSpecs: [[String: Any]] = []
        var zip = Data()
        if !libs.isEmpty {
            var entries: [(name: String, data: Data)] = []
            for (i, l) in libs.enumerated() {
                if let exec = l.exec {
                    for f in l.files { entries.append((name: "libs/\(i)/" + f.rel, data: f.data)) }
                    libSpecs.append(["name": l.name, "framework": l.name, "exec": exec,
                                     "files": l.files.map { ["rel": $0.rel, "entry": "libs/\(i)/" + $0.rel] }])
                } else {
                    entries.append((name: "libs/\(i)/" + l.name, data: l.data))
                    libSpecs.append(["name": l.name, "entry": "libs/\(i)/" + l.name])
                }
            }
            zip = ZipStore.build(entries)
        }
        stage = .uploading; message = "Starting the build on the server…"; queue = 0
        let settings: [String: Any] = [
            "base": o.rpath ? "rpath" : "exe", "folder": o.frameworksFolder ? "Frameworks/" : "", "kind": "load",
            "stripSig": o.stripSignature, "rewrite": true,
            "edit": ["name": o.name.trimmingCharacters(in: .whitespaces), "bid": o.bid.trimmingCharacters(in: .whitespaces), "minOS": o.minOS.trimmingCharacters(in: .whitespaces)],
            "junk": ["sig": true, "prov": true, "plug": false, "watch": false], "remove": o.remove,
        ]
        let spec: [String: Any] = ["src": src, "a": ["bid": app.bid, "name": app.name], "ver": source.version, "fname": Self.safe(app.name),
                                   "settings": settings, "libs": libSpecs, "bundleSize": zip.count]
        let st: Started = try await Api.shared.post("/api/build/start", json: spec)
        jobID = st.id
        if !zip.isEmpty {
            let chunk = max(1_048_576, st.chunk ?? 16_777_216)
            var off = 0
            while off < zip.count {
                try Task.checkCancellation()
                let end = min(zip.count, off + chunk)
                message = "Sending your libraries… \(off * 100 / zip.count)%"
                _ = try await Api.shared.upload("PUT", "/api/build/\(st.id)?offset=\(off)", body: zip.subdata(in: off..<end))
                off = end
            }
        }
        let _: Started = try await Api.shared.post("/api/build/\(st.id)/run")

        // 3. wait for the server
        stage = .building; message = "Waiting for a free builder…"
        var misses = 0
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let j: JobState
            do { j = try await Api.shared.get("/api/build/" + st.id); misses = 0 }
            catch let e as ApiError where e.status == 404 { throw ApiError.server("The server lost track of this build. Build it again.", 0) }
            catch { misses += 1; if misses > 60 { throw error }; continue }
            if j.status == "error" { throw ApiError.server(j.error ?? "The build failed.", 0) }
            if j.status == "done", let out = j.out {
                outName = out.fname ?? "app.ipa"; outSize = out.size ?? 0; outSha = out.sha256 ?? ""
                outLink = out.url.flatMap { URL(string: $0) }
                added = (out.loads ?? []).compactMap { $0.name }
                pct = 1; stage = .done; message = "Build completed"
                if let link = outLink {
                    SignedStore.shared.add(SignedEntry(
                        id: jobID.isEmpty ? UUID().uuidString : jobID,
                        name: o.name.isEmpty ? app.name : o.name,
                        bid: o.bid.isEmpty ? app.bid : o.bid,
                        version: source.version.isEmpty ? (app.current?.version ?? "") : source.version,
                        icon: app.icon?.absoluteString, date: Date(), link: link.absoluteString, size: outSize))
                }
                return
            }
            message = j.msg ?? "Working…"; pct = Double(j.pct ?? 0) / 100; queue = j.queue ?? 0
        }
    }

    private func fail(_ e: Error) async {
        stage = .failed
        error = e.localizedDescription
        if let a = e as? ApiError, a.status == 409 { error = "A build is already running on your account." }
        // the server's own report for this build (steps, settings, trimmed trace), as a file to send
        var text = "Uncrypt build error\n\(Date())\nApp: \(error)\n"
        if !jobID.isEmpty, let d = try? await Api.shared.request("GET", "/api/build/\(jobID)/diag"), let s = String(data: d, encoding: .utf8) { text += "\n" + s }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("decrypt-team-error-log.txt")
        if (try? text.write(to: f, atomically: true, encoding: .utf8)) != nil { errorLog = f }
    }

    func downloadIPA() {
        guard !jobID.isEmpty, !downloading else { return }
        downloading = true; downloadPct = 0; downloadError = ""
        let name = outName
        Task {
            do {
                let url = try await FileDownloader().download(path: "/api/build/\(jobID)/file", name: name) { p in
                    Task { @MainActor in self.downloadPct = p }
                }
                localFile = url
            } catch { downloadError = error.localizedDescription }
            downloading = false
        }
    }

    static func safe(_ s: String) -> String {
        let t = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "." ? Character($0) : "-" }
        let r = String(t).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return r.isEmpty ? "app" : String(r.prefix(60))
    }
}

// MARK: - Screen

struct BuildScreen: View {
    let app: AppEntry
    let storeInfo: StoreInfo?

    @StateObject private var model = BuildModel()
    @State private var useStore = false
    @State private var opts = BuildOptions()
    @State private var libs: [PickedLib] = []
    @State private var importing = false
    @State private var importFramework = false
    @State private var importError = ""
    @State private var cmds: [LoadCmd] = []
    @State private var cmdsState = CmdsState.idle
    @State private var strip: Set<String> = []
    @State private var share: ShareItem?

    private struct ShareItem: Identifiable { let id = UUID(); let items: [Any] }
    struct LoadCmd: Identifiable, Hashable { let kind: String; let path: String; var id: String { path } }
    enum CmdsState: Equatable { case idle, loading, loaded, failed(String) }

    private var repoURL: URL? { app.current?.url }
    private var storeID: String? { (storeInfo?.id).flatMap { $0.isEmpty ? nil : $0 } }
    private var storeVer: String { storeInfo?.ver ?? "" }
    private var newer: Bool { !storeVer.isEmpty && app.current.map { compareVersions(storeVer, $0.version) > 0 } ?? false }
    private var source: BuildSource? {
        if useStore, let id = storeID { return .store(id: id, version: storeVer) }
        if let u = repoURL, let v = app.current { return .repo(u, version: v.version) }
        if let id = storeID { return .store(id: id, version: storeVer) }
        return nil
    }
    private var preview: String {
        let base = opts.rpath ? "@rpath/" : "@executable_path/"
        return base + (opts.frameworksFolder ? "Frameworks/" : "") + "dtx.dylib"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if model.stage == .idle { setup } else { progress }
            }
            .padding(16)
        }
        .background(AppBackground())
        .navigationTitle("Decrypt & Inject").navigationBarTitleDisplayMode(.inline)
        .onAppear { useStore = newer || repoURL == nil }
        .onChange(of: storeInfo?.ver) { _ in if model.stage == .idle { useStore = newer || repoURL == nil } }
        .fileImporter(isPresented: $importing, allowedContentTypes: importFramework ? [.folder] : [.data], allowsMultipleSelection: !importFramework) { result in
            guard case .success(let urls) = result else { return }
            for u in urls { if importFramework { addFramework(u) } else { addDylib(u) } }
        }
        .task(id: repoURL?.absoluteString ?? "") { await loadCommands() }
        .sheet(item: $share) { ShareSheet(items: $0.items) }
    }

    // MARK: adding libraries

    private func addDylib(_ u: URL) {
        guard u.pathExtension.lowercased() == "dylib" else { importError = "\(u.lastPathComponent) isn't a .dylib."; return }
        let ok = u.startAccessingSecurityScopedResource(); defer { if ok { u.stopAccessingSecurityScopedResource() } }
        guard let d = try? Data(contentsOf: u) else { importError = "Couldn't read \(u.lastPathComponent)."; return }
        if u.lastPathComponent.lowercased() == "dtx.dylib" { importError = "dtx.dylib is already added to every build."; return }
        libs.removeAll { $0.name == u.lastPathComponent }
        libs.append(PickedLib(name: u.lastPathComponent, data: d))
    }

    private func addFramework(_ root: URL) {
        let name = root.lastPathComponent
        guard name.lowercased().hasSuffix(".framework") else { importError = "\(name) isn't a .framework folder."; return }
        let ok = root.startAccessingSecurityScopedResource(); defer { if ok { root.stopAccessingSecurityScopedResource() } }
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { importError = "Couldn't open \(name)."; return }
        var files: [FrameworkFile] = []
        let base = root.pathComponents.count
        for case let f as URL in en {
            guard (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true, let d = try? Data(contentsOf: f) else { continue }
            let rel = f.pathComponents.dropFirst(base).joined(separator: "/")
            if !rel.isEmpty { files.append(FrameworkFile(rel: rel, data: d)) }
        }
        // the binary's name comes from the framework's own Info.plist, or the folder name
        var exec = String(name.dropLast(".framework".count))
        if let plist = files.first(where: { $0.rel == "Info.plist" }),
           let obj = try? PropertyListSerialization.propertyList(from: plist.data, options: [], format: nil) as? [String: Any],
           let e = obj["CFBundleExecutable"] as? String, !e.isEmpty { exec = e }
        guard files.contains(where: { $0.rel == exec }) else { importError = "\(name) has no binary named \(exec)."; return }
        libs.removeAll { $0.name == name }
        libs.append(PickedLib(name: name, exec: exec, files: files))
    }

    // MARK: the app's existing load commands (from the repo's IPA, read on the server)

    private func loadCommands() async {
        cmds = []; strip = []
        guard let u = repoURL else { cmdsState = .idle; return }
        cmdsState = .loading
        do {
            let s: PluginStart = try await Api.shared.post("/api/plugins/loadcmds/run", json: ["src": ["url": u.absoluteString], "options": ["system": false]])
            guard let id = s.id else { throw ApiError.bad }
            for _ in 0..<120 {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                let j: PluginJob = try await Api.shared.get("/api/plugins/jobs/" + id)
                if j.status == "done" {
                    let rows = j.result?.sections?.first(where: { $0.kind == "table" })?.rows ?? []
                    cmds = rows.filter { $0.count > 1 && $0[0] != "rpath" }.map { LoadCmd(kind: $0[0], path: $0[1]) }
                    cmdsState = .loaded; return
                }
                if j.status == "err" || j.status == "cancel" { throw ApiError.server(j.error ?? "Couldn't read the load commands.", 0) }
            }
            throw ApiError.server("Reading the load commands took too long.", 0)
        } catch is CancellationError { return }
        catch { cmdsState = .failed(error.localizedDescription) }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 14) {
            AppIconView(url: app.icon ?? AppDetailView.https(storeInfo?.icon), name: app.name, size: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.title3.bold()).foregroundStyle(.white).lineLimit(2)
                Text(app.bid).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    // MARK: setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            sourceCard
            injectionCard
            commandsCard
            libsCard
            infoCard
            if !model.error.isEmpty { Text(model.error).font(.footnote).foregroundStyle(Color.red) }
            Button {
                guard let s = source else { return }
                var o = opts; o.remove = cmds.map(\.path).filter { strip.contains($0) }
                model.start(app: app, source: s, options: o, libs: libs)
            } label: {
                Label("Build IPA", systemImage: "wand.and.stars").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(AccentButtonStyle()).disabled(source == nil)
            Text("The server does the work. Leave this screen open until it finishes.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SOURCE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if repoURL != nil && storeID != nil {
                Picker("", selection: $useStore) {
                    Text("Repo v\(app.current?.version ?? "")").tag(false)
                    Text("App Store v\(storeVer)").tag(true)
                }.pickerStyle(.segmented)
            }
            Text(useStore || repoURL == nil
                 ? "Decrypts this app from the App Store on the server, then injects. Uses one decrypt from your daily limit."
                 : "Uses the repo's IPA as it is. Nothing is decrypted.")
                .font(.footnote).foregroundStyle(.secondary)
            if newer && !useStore { Label("The App Store has v\(storeVer), newer than the repo.", systemImage: "arrow.up.circle.fill").font(.footnote).foregroundStyle(Color.dtAccent) }
            if repoURL == nil && storeID == nil { Text("This app has no repo download and no App Store match.").font(.footnote).foregroundStyle(Color.red) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private var injectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DYLIB INJECTION").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Inject Path").font(.subheadline.bold()).foregroundStyle(.white)
                Picker("", selection: $opts.rpath) { Text("@executable_path").tag(false); Text("@rpath").tag(true) }.pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Inject Folder").font(.subheadline.bold()).foregroundStyle(.white)
                Picker("", selection: $opts.frameworksFolder) { Text("/").tag(false); Text("Frameworks/").tag(true) }.pickerStyle(.segmented)
            }
            Text(preview).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.dtAccent)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Toggle("Remove the old signature", isOn: $opts.stripSignature).font(.subheadline).tint(.dtAccent)
        }
        .card()
    }

    private var libsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("LIBRARIES").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 8)
            libRow("dtx.dylib", "Always added", locked: true) {}
            ForEach(libs) { l in
                Divider().overlay(Color.dtLine)
                libRow(l.name, (l.isFramework ? "Framework · " : "") + ByteCountFormatter.string(fromByteCount: l.size, countStyle: .file), locked: false) { libs.removeAll { $0.id == l.id } }
            }
            Divider().overlay(Color.dtLine)
            HStack(spacing: 16) {
                Button { importError = ""; importFramework = false; importing = true } label: {
                    Label("Add .dylib", systemImage: "plus.circle.fill").font(.subheadline.weight(.semibold)).padding(.vertical, 12)
                }
                Button { importError = ""; importFramework = true; importing = true } label: {
                    Label("Add .framework", systemImage: "folder.badge.plus").font(.subheadline.weight(.semibold)).padding(.vertical, 12)
                }
            }
            if !importError.isEmpty { Text(importError).font(.caption).foregroundStyle(Color.red) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func libRow(_ name: String, _ sub: String, locked: Bool, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: locked ? "lock.fill" : (name.lowercased().hasSuffix(".framework") ? "square.stack.3d.up" : "shippingbox")).foregroundStyle(Color.dtAccent).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).foregroundStyle(.white).lineLimit(1)
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !locked { Button(role: .destructive, action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
        }
        .padding(.vertical, 10)
    }

    private var commandsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EXISTING LOAD COMMANDS" + (cmdsState == .loaded ? " (\(cmds.count))" : "")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            switch cmdsState {
            case .idle:
                Text("Shown for the repo's IPA. This app has none, so there is nothing to strip.").font(.footnote).foregroundStyle(.secondary)
            case .loading:
                HStack(spacing: 8) { ProgressView(); Text("Reading the repo's IPA on the server…").font(.footnote).foregroundStyle(.secondary) }
            case .failed(let m):
                Text(m).font(.footnote).foregroundStyle(Color.red)
                Button("Try again") { Task { await loadCommands() } }.buttonStyle(.bordered).tint(.dtAccent)
            case .loaded:
                if cmds.isEmpty { Text("No extra libraries are loaded by this app.").font(.footnote).foregroundStyle(.secondary) }
                else {
                    Text("Tap one to strip it from the app.").font(.footnote).foregroundStyle(.secondary)
                    ForEach(cmds) { c in
                        Button { if strip.contains(c.path) { strip.remove(c.path) } else { strip.insert(c.path) } } label: {
                            HStack(spacing: 10) {
                                Image(systemName: strip.contains(c.path) ? "trash.circle.fill" : "circle").foregroundStyle(strip.contains(c.path) ? Color.red : Color.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(strip.contains(c.path) ? Color.red : .white)
                                        .strikethrough(strip.contains(c.path)).multilineTextAlignment(.leading)
                                    Text(c.kind).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if useStore { Text("The commands are read from the repo's IPA. The same ones are stripped from the decrypted App Store build.").font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("APP INFO (OPTIONAL)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            infoField("Name", app.name, $opts.name)
            infoField("Bundle ID", app.bid, $opts.bid)
            infoField("Minimum iOS", "e.g. 14.0", $opts.minOS)
            Text("Leave a field empty to keep the app's own value.").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func infoField(_ title: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold()).foregroundStyle(.white)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        }
    }

    // MARK: progress, result, failure

    private var progress: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.stage {
            case .done: done
            case .failed: failed
            default: working
            }
        }
    }

    private var steps: [(String, BuildStage)] {
        (useStore || repoURL == nil) ? [("Decrypt", .decrypting), ("Prepare", .uploading), ("Build", .building)] : [("Prepare", .uploading), ("Build", .building)]
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                let cur = steps.firstIndex { $0.1 == model.stage } ?? 0
                HStack(spacing: 10) {
                    if i < cur { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.dtGreen) }
                    else if i == cur { ProgressView() }
                    else { Image(systemName: "circle").foregroundStyle(.secondary) }
                    Text(s.0).foregroundStyle(i <= cur ? .white : .secondary)
                }
            }
            if model.stage == .building { ProgressView(value: max(0.02, model.pct)).tint(.dtAccent) }
            Text(model.message + (model.queue > 0 ? " · \(model.queue) in line" : "")).font(.footnote).foregroundStyle(.secondary)
            Button("Cancel build", role: .destructive) { model.cancel() }.buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Build completed", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(Color.dtGreen)
            Text(model.outName).font(.subheadline.bold()).foregroundStyle(.white).lineLimit(2)
            Text([ByteCountFormatter.string(fromByteCount: model.outSize, countStyle: .file), model.added.isEmpty ? nil : "Injected: " + model.added.joined(separator: ", ")]
                .compactMap { $0 }.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
            if let f = model.localFile {
                Button { share = ShareItem(items: [f]) } label: { Label("Save or share IPA", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(.vertical, 6) }
                    .buttonStyle(AccentButtonStyle())
            } else {
                Button { model.downloadIPA() } label: {
                    Label(model.downloading ? "Downloading… \(Int(model.downloadPct * 100))%" : "Download IPA", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(AccentButtonStyle()).disabled(model.downloading)
                if model.downloading { ProgressView(value: model.downloadPct).tint(.dtAccent) }
            }
            if !model.downloadError.isEmpty { Text(model.downloadError).font(.footnote).foregroundStyle(Color.red) }
            if let link = model.outLink {
                HStack {
                    Button { UIPasteboard.general.string = link.absoluteString } label: { Label("Copy link", systemImage: "link") }.buttonStyle(.bordered).tint(.dtAccent)
                    Menu {
                        ForEach(Sideloaders.all, id: \.0) { s in Button(s.0) { if let l = URL(string: s.1(link.absoluteString)) { UIApplication.shared.open(l) } } }
                    } label: { Label("Install with…", systemImage: "arrow.down.app") }.buttonStyle(.bordered).tint(.dtAccent)
                }
            }
            Button("Build again") { model.reset() }.font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private var failed: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Build failed", systemImage: "xmark.octagon.fill").font(.headline).foregroundStyle(Color.red)
            Text(model.error).font(.subheadline).foregroundStyle(.white)
            if let f = model.errorLog {
                Button { share = ShareItem(items: [f]) } label: { Label("Share error log", systemImage: "doc.text").frame(maxWidth: .infinity).padding(.vertical, 6) }
                    .buttonStyle(AccentButtonStyle())
            }
            if model.error.hasPrefix("A build is already running") {
                Button("Cancel the running build") { Task { await model.cancelStale() } }.buttonStyle(.bordered).tint(.dtAccent)
            }
            Button("Back to settings") { model.reset() }.buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }
}

enum Sideloaders {
    static let all: [(String, (String) -> String)] = [
        ("Feather", { "feather://install/" + $0 }),
        ("E-Sign", { "esign://install?url=" + $0.urlEncoded }),
        ("GBox", { "gbox://install?url=" + $0.urlEncoded }),
        ("FlareStore", { "flarestore://install?url=" + $0.urlEncoded }),
        ("AltStore", { "altstore://install?url=" + $0.urlEncoded }),
    ]
}
