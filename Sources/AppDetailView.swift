import SwiftUI

struct AppDetailView: View {
    @EnvironmentObject var store: RepoStore
    @EnvironmentObject var session: Session
    @Environment(\.openURL) private var openURL
    let app: AppEntry

    enum DetailTab: String, CaseIterable { case dylibs = "Dylibs", frameworks = "Frameworks", info = "Info", tools = "Tools" }

    @State private var tab: DetailTab = .dylibs
    @State private var storeInfo: StoreInfo?
    @State private var sets: [SavedSet] = []
    @State private var setID = ""
    @State private var loaded = false
    @State private var studio: IdentifiedURL?

    private let sideloaders: [(String, (String) -> String)] = [
        ("Feather", { "feather://install/" + $0 }),
        ("E-Sign", { "esign://install?url=" + $0.urlEncoded }),
        ("GBox", { "gbox://install?url=" + $0.urlEncoded }),
        ("FlareStore", { "flarestore://install?url=" + $0.urlEncoded }),
        ("AltStore", { "altstore://install?url=" + $0.urlEncoded }),
    ]

    private var curSet: SavedSet? { sets.first { $0.id == setID } ?? sets.first }
    private var items: [SetItem] { curSet?.items ?? [] }
    private var dylibs: [SetItem] { items.filter { $0.type != "framework" } }
    private var frameworks: [SetItem] { items.filter { $0.type == "framework" } }
    private var update: Bool {
        guard let latest = storeInfo?.ver, let cur = app.current?.version else { return false }
        return compareVersions(latest, cur) > 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerCard
                if update, let v = storeInfo?.ver { banner(v) }
                Picker("", selection: $tab) {
                    ForEach(DetailTab.allCases, id: \.self) { t in
                        Text(t == .dylibs ? "Dylibs (\(dylibs.count))" : t == .frameworks ? "Frameworks (\(frameworks.count))" : t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                content
                actions
                versions
            }
            .padding(16)
        }
        .background(Color.dtBG)
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $studio) { StudioSheet(url: $0.url).ignoresSafeArea() }
    }

    // MARK: header

    private var headerCard: some View {
        HStack(spacing: 14) {
            AppIconView(url: app.icon ?? Self.https(storeInfo?.icon), name: app.name, size: 68)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.title3.bold()).foregroundStyle(.white).lineLimit(2)
                Text(app.bid).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    if let c = app.current { Pill(text: "Installed: v" + c.version, tone: .gray) }
                    if let l = storeInfo?.ver, !l.isEmpty { Pill(text: "Latest: v" + l + (update ? " ↑" : ""), tone: .dtGreen) }
                }
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    private func banner(_ v: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundStyle(Color.dtAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Newer version available").font(.subheadline.bold()).foregroundStyle(.white)
                Text("v" + v).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.dtAccent.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.dtAccent.opacity(0.6)))
    }

    // MARK: tabs

    @ViewBuilder private var content: some View {
        switch tab {
        case .dylibs: itemList(dylibs, empty: "No dylibs saved for this app yet.")
        case .frameworks: itemList(frameworks, empty: "No frameworks saved for this app yet.")
        case .info: infoCard
        case .tools: ToolsPanel(url: app.current?.url?.absoluteString ?? "")
        }
    }

    private func itemList(_ list: [SetItem], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if sets.count > 1 {
                Picker("Saved set", selection: Binding(get: { curSet?.id ?? "" }, set: { setID = $0 })) {
                    ForEach(sets) { s in Text("v\(s.version) · \(s.count) items").tag(s.id) }
                }
                .pickerStyle(.menu).padding(.bottom, 8)
            }
            if !loaded { ProgressView().frame(maxWidth: .infinity).padding(20) }
            else if list.isEmpty { Text(empty).foregroundStyle(.secondary).padding(.vertical, 18) }
            ForEach(list) { it in
                HStack(spacing: 10) {
                    Image(systemName: it.type == "framework" ? "square.stack.3d.up" : "shippingbox").foregroundStyle(Color.dtAccent).frame(width: 24)
                    Text(it.name).foregroundStyle(.white).lineLimit(1)
                    Spacer()
                    if it.size > 0 { Text(ByteCountFormatter.string(fromByteCount: it.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 10)
                if it.id != list.last?.id { Divider().overlay(Color.dtLine) }
            }
        }
        .card()
    }

    private var infoCard: some View {
        VStack(spacing: 0) {
            kv("Name", app.name)
            kv("Bundle ID", app.bid)
            if let c = app.current { kv("In the repo", "v" + c.version) }
            if let l = storeInfo?.ver, !l.isEmpty { kv("Latest", "v" + l) }
            if let m = storeInfo?.minos, !m.isEmpty { kv("Minimum iOS", m) }
            kv("Repo", app.repoName)
            kv("Saved sets", sets.isEmpty ? "None" : sets.map { "v\($0.version) (\($0.count))" }.joined(separator: ", "))
        }
        .card()
    }

    private func kv(_ k: String, _ v: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Text(k).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(v).foregroundStyle(.white).multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 10)
            Divider().overlay(Color.dtLine)
        }
    }

    // MARK: actions and versions

    private var actions: some View {
        Button {
            let bid = app.bid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? app.bid
            let repo = app.repoURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let u = URL(string: Api.shared.base + "/studio/inject/" + bid + "?repo=" + repo) { studio = IdentifiedURL(url: u) }
        } label: {
            Label("Decrypt & Inject", systemImage: "wand.and.stars").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent).tint(.dtAccent)
    }

    private var versions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Versions in \(app.repoName)").font(.headline).foregroundStyle(.white)
            if app.versions.isEmpty { Text("This repo lists no downloads for this app.").foregroundStyle(.secondary) }
            ForEach(app.versions) { v in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("v" + v.version).font(.subheadline.bold()).foregroundStyle(.white)
                        Spacer()
                        if v.size > 0 { Text(ByteCountFormatter.string(fromByteCount: v.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                    }
                    if let u = v.url {
                        HStack {
                            Button("Download IPA") { openURL(u) }.buttonStyle(.bordered).tint(.dtAccent)
                            Menu("Install with…") {
                                ForEach(sideloaders, id: \.0) { s in
                                    Button(s.0) { if let l = URL(string: s.1(u.absoluteString)) { openURL(l) } }
                                }
                            }.buttonStyle(.bordered).tint(.dtAccent)
                        }
                    }
                }
                .padding(.vertical, 6)
                if v.id != app.versions.last?.id { Divider().overlay(Color.dtLine) }
            }
        }
        .card()
    }

    // MARK: data

    private func load() async {
        let bid = app.bid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? app.bid
        async let up: UpstreamReply? = try? Api.shared.get("/api/repo/upstream?bids=" + bid)
        async let ss: SetsReply? = try? Api.shared.get("/api/dylibs/app/" + bid)
        let u = await up, s = await ss
        storeInfo = u?.items?[app.bid]?.store ?? u?.items?.values.first?.store
        sets = (s?.sets ?? []).sorted { compareVersions($0.version, $1.version) > 0 }
        if setID.isEmpty {
            setID = (sets.first { $0.version == app.current?.version } ?? sets.first)?.id ?? ""
        }
        loaded = true
    }

    static func https(_ s: String?) -> URL? {
        guard let s, let u = URL(string: s), u.scheme == "https" else { return nil }
        return u
    }
}

// MARK: - Tools (plugins that run on the server)

struct ToolsPanel: View {
    @EnvironmentObject var session: Session
    let url: String
    @State private var list: [PluginInfo] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if url.isEmpty {
                Text("Tools open the repo's IPA. This app has no repo IPA.").foregroundStyle(.secondary)
            } else if !loaded {
                ProgressView().frame(maxWidth: .infinity).padding(20)
            } else if list.isEmpty {
                Text("No tools are installed on this server.").foregroundStyle(.secondary)
            } else {
                if !session.signedIn {
                    Button { session.showLogin = true } label: { Label("Sign in to run tools", systemImage: "person").font(.subheadline.weight(.semibold)) }
                        .buttonStyle(.bordered).tint(.dtAccent)
                }
                ForEach(list) { p in ToolRow(plugin: p, url: url) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .task { await load() }
    }

    private func load() async {
        let r: PluginList? = try? await Api.shared.get("/api/plugins")
        list = r?.items ?? []; loaded = true
    }
}

struct ToolRow: View {
    @EnvironmentObject var session: Session
    let plugin: PluginInfo
    let url: String
    @State private var values: [String: String] = [:]
    @State private var flags: [String: Bool] = [:]
    @State private var running = false
    @State private var jobID = ""
    @State private var message = ""
    @State private var failed = false
    @State private var sections: [PluginSection] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.name).font(.subheadline.bold()).foregroundStyle(.white)
                    Text(plugin.description).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(running ? "Cancel" : "Run") { running ? cancel() : start() }
                    .buttonStyle(.bordered).tint(.dtAccent).disabled(!session.signedIn)
            }
            ForEach(plugin.options) { o in
                if o.type == "bool" {
                    Toggle(o.label, isOn: Binding(get: { flags[o.key] ?? (o.def == "true") }, set: { flags[o.key] = $0 })).font(.subheadline)
                } else {
                    TextField(o.label, text: Binding(get: { values[o.key] ?? o.def }, set: { values[o.key] = $0 }))
                        .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(o.type == "number" ? .numberPad : .default)
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary) }
            ForEach(sections) { SectionView(section: $0) }
            Divider().overlay(Color.dtLine)
        }
    }

    private func start() {
        running = true; failed = false; message = "Starting…"; sections = []
        var opts: [String: Any] = [:]
        for o in plugin.options { opts[o.key] = o.type == "bool" ? (flags[o.key] ?? (o.def == "true")) : (values[o.key] ?? o.def) }
        Task {
            do {
                let s: PluginStart = try await Api.shared.post("/api/plugins/\(plugin.id)/run", json: ["src": ["url": url], "options": opts])
                jobID = s.id ?? ""
                await poll()
            } catch {
                failed = true; message = error.localizedDescription; running = false
            }
        }
    }

    private func poll() async {
        while running, !jobID.isEmpty {
            do {
                let j: PluginJob = try await Api.shared.get("/api/plugins/jobs/" + jobID)
                switch j.status ?? "" {
                case "done": sections = j.result?.sections ?? []; message = ""; running = false; return
                case "err", "cancel": failed = (j.status == "err"); message = j.error ?? "Stopped."; running = false; return
                default: message = (j.msg ?? "Working…") + ((j.pct ?? 0) > 0 ? " · \(j.pct ?? 0)%" : "")
                }
            } catch {
                failed = true; message = error.localizedDescription; running = false; return
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
    }

    private func cancel() {
        let id = jobID; running = false; message = "Stopped."
        Task { let _: PluginStart? = try? await Api.shared.post("/api/plugins/jobs/\(id)/cancel") }
    }
}

struct SectionView: View {
    let section: PluginSection
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
            switch section.kind {
            case "kv":
                ForEach(Array(section.rows.enumerated()), id: \.offset) { _, r in
                    HStack(alignment: .top) {
                        Text(r.first ?? "").foregroundStyle(.secondary)
                        Spacer(minLength: 10)
                        Text(r.count > 1 ? r[1] : "").foregroundStyle(.white).multilineTextAlignment(.trailing)
                    }.font(.footnote)
                }
            case "table":
                ForEach(Array(section.rows.enumerated()), id: \.offset) { _, r in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(r.enumerated()), id: \.offset) { i, c in
                            Text(c).foregroundStyle(i == 0 ? Color.dtAccent : .white).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.font(.system(size: 12, design: .monospaced))
                }
            case "list":
                Text(section.items.isEmpty ? "Nothing found." : section.items.joined(separator: "\n"))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.white).textSelection(.enabled)
            default:
                Text(section.text).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white).textSelection(.enabled)
            }
            if !section.note.isEmpty { Text(section.note).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}
