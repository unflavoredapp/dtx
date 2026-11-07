import SwiftUI
import UniformTypeIdentifiers

/// A dylib the person imported for batch injection.
struct BatchDylib: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var weak: Bool = false
    var enabled: Bool = true
}

@MainActor
final class BatchDylibStore: ObservableObject {
    static let shared = BatchDylibStore()
    @Published private(set) var items: [BatchDylib] = []
    private let key = "dt.batch.dylibs"
    private var folder: URL { AppPaths.dir("batch-dylibs") }

    private init() {
        if let d = UserDefaults.standard.data(forKey: key), let list = try? JSONDecoder().decode([BatchDylib].self, from: d) { items = list }
        items.removeAll { !FileManager.default.fileExists(atPath: url(for: $0).path) }
    }

    func url(for d: BatchDylib) -> URL { folder.appendingPathComponent(d.id + ".dylib") }

    func add(from source: URL) throws {
        let d = BatchDylib(id: UUID().uuidString, name: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url(for: d))
        items.insert(d, at: 0)
        save()
    }

    func update(_ d: BatchDylib) {
        guard let i = items.firstIndex(where: { $0.id == d.id }) else { return }
        items[i] = d
        save()
    }

    func delete(_ d: BatchDylib) {
        try? FileManager.default.removeItem(at: url(for: d))
        items.removeAll { $0.id == d.id }
        save()
    }

    var active: [(url: URL, weak: Bool)] {
        items.filter { $0.enabled }.map { (url: url(for: $0), weak: $0.weak) }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
}

/// Batch: inject the chosen dylibs into many apps at once and repackage them. Nothing is signed here: the
/// steps run as a parallel graph (downloads, unpacking, copying and repackaging of different apps overlap),
/// and each result is an unsigned IPA you sign later in Signer.
struct BatchView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dylibs = BatchDylibStore.shared
    @ObservedObject private var decrypted = SignedStore.shared
    @ObservedObject private var onPhone = SignedBuildStore.shared
    @EnvironmentObject var store: RepoStore

    /// One app the person built, from either list.
    struct Target: Identifiable, Hashable {
        let id: String
        let name: String
        let sub: String
        let remote: String?      // download link of a Decrypt build
        let local: URL?          // IPA already on this phone
        var added = false        // added by hand (repo app or loose file), not one of your builds
    }

    enum Phase: Equatable { case waiting, working(String), done, failed(String) }

    @State private var picked: Set<String> = []
    @State private var phases: [String: Phase] = [:]
    @State private var importing = false
    @State private var running = false
    @State private var progressDone: [String: Int] = [:]
    @State private var progressTotal: [String: Int] = [:]
    @State private var message: String?
    @State private var extras: [Target] = []
    @State private var importingIPA = false
    @State private var showRepoPicker = false

    private var targets: [Target] {
        var out: [Target] = extras
        for e in decrypted.items {
            out.append(Target(id: "d-" + e.id, name: e.name, sub: e.version + " • " + e.bid, remote: e.link, local: nil))
        }
        for b in onPhone.entries {
            out.append(Target(id: "p-" + b.id, name: b.name, sub: b.version + " • " + b.bundleID, remote: nil, local: b.ipaURL))
        }
        return out
    }

    var body: some View {
        NavigationStack {
            List {
                dylibSection
                appsSection
                addMoreSection
                optionsSection
                if let message { Section { Text(message).font(.footnote).foregroundStyle(.orange) } }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("Batch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(running ? "Working…" : "Inject \(picked.count)") { Task { await runBatch() } }
                        .disabled(running || picked.isEmpty || dylibs.active.isEmpty)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                importDylibs(result)
            }
            .fileImporter(isPresented: $importingIPA, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                importIPAs(result)
            }
            .sheet(isPresented: $showRepoPicker) {
                BatchRepoPicker { apps in apps.forEach { addRepoApp($0) } }.environmentObject(store)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: sections

    private var dylibSection: some View {
        Section {
            if dylibs.items.isEmpty {
                Text("Add the .dylib files to inject.").foregroundStyle(.secondary).font(.footnote)
            }
            ForEach(dylibs.items) { d in dylibRow(d) }
                .onDelete { idx in
                    let list = dylibs.items
                    for i in idx { dylibs.delete(list[i]) }
                }
            Button { importing = true } label: { Label("Add dylibs", systemImage: "plus.circle.fill").foregroundStyle(Color.dtAccent) }
                .disabled(running)
        } header: { Text("Dylibs") }
    }

    private func dylibRow(_ d: BatchDylib) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { d.enabled }, set: { var n = d; n.enabled = $0; dylibs.update(n) }))
                .labelsHidden().tint(Color.dtAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.name).foregroundStyle(.white).lineLimit(1)
                Text(d.weak ? "Weak load" : "Required").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(d.weak ? "Weak" : "Required") { var n = d; n.weak.toggle(); dylibs.update(n) }
                .font(.caption.weight(.semibold)).buttonStyle(.bordered).tint(Color.dtAccent)
        }
    }

    private var appsSection: some View {
        Section {
            if targets.isEmpty {
                Text("Nothing built yet. Decrypt an app or sign one first.").foregroundStyle(.secondary).font(.footnote)
            }
            ForEach(targets) { t in targetRow(t) }
        } header: {
            HStack {
                Text("Your builds")
                Spacer()
                Button(picked.count == targets.count && !targets.isEmpty ? "None" : "All") {
                    picked = picked.count == targets.count ? [] : Set(targets.map(\.id))
                }
                .font(.caption.weight(.semibold)).disabled(running)
            }
        }
    }

    private var addMoreSection: some View {
        Section {
            Button { showRepoPicker = true } label: { Label("Add an app from your repos", systemImage: "square.grid.2x2").foregroundStyle(Color.dtAccent) }
                .disabled(running)
            Button { importingIPA = true } label: { Label("Add .ipa files", systemImage: "doc.badge.plus").foregroundStyle(Color.dtAccent) }
                .disabled(running)
        } header: { Text("Optional") } footer: { Text("Your builds are listed above. Repo apps and loose IPAs are optional extras.") }
    }

    private func targetRow(_ t: Target) -> some View {
        let on = picked.contains(t.id)
        let phase = phases[t.id] ?? .waiting
        return Button {
            if on { picked.remove(t.id) } else { picked.insert(t.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Color.dtAccent : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name).foregroundStyle(.white).lineLimit(1)
                    Text(t.sub).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if case .failed(let m) = phase { Text(m).font(.caption2).foregroundStyle(.red).lineLimit(3) }
                    if case .working = phase, let total = progressTotal[t.id], total > 0 {
                        ProgressView(value: Double(progressDone[t.id] ?? 0), total: Double(total)).tint(Color.dtAccent)
                    }
                }
                Spacer()
                phaseView(phase)
            }
        }
        .buttonStyle(.plain)
        .disabled(running)
    }

    @ViewBuilder private func phaseView(_ p: Phase) -> some View {
        switch p {
        case .waiting: EmptyView()
        case .working(let label): Text(label).font(.caption).foregroundStyle(Color.dtAccent)
        case .done: Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private var optionsSection: some View {
        Section {
            Label("Nothing is signed here. Results are unsigned IPAs in Signed; sign them later in Signer.", systemImage: "info.circle")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: actions

    private func importDylibs(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let e): message = e.localizedDescription
        case .success(let urls):
            message = nil
            for u in urls {
                let scoped = u.startAccessingSecurityScopedResource()
                defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                guard u.pathExtension.lowercased() == "dylib" else { message = "\(u.lastPathComponent) isn't a .dylib."; continue }
                do { try dylibs.add(from: u) } catch { message = error.localizedDescription }
            }
        }
    }

    private func importIPAs(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let e): message = e.localizedDescription
        case .success(let urls):
            message = nil
            let folder = AppPaths.dir("batch-imports")
            for u in urls {
                let scoped = u.startAccessingSecurityScopedResource()
                defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                guard u.pathExtension.lowercased() == "ipa" else { message = "\(u.lastPathComponent) isn't an .ipa."; continue }
                let dest = folder.appendingPathComponent(UUID().uuidString + ".ipa")
                do {
                    try FileManager.default.copyItem(at: u, to: dest)
                    let t = Target(id: "f-" + dest.lastPathComponent, name: u.deletingPathExtension().lastPathComponent,
                                   sub: "Loose file", remote: nil, local: dest, added: true)
                    extras.append(t); picked.insert(t.id)
                } catch { message = error.localizedDescription }
            }
        }
    }

    private func addRepoApp(_ app: AppEntry) {
        guard let link = app.current?.url?.absoluteString else { message = "\(app.name) has no download link."; return }
        let version: String = app.current.map { "v" + $0.version } ?? ""
        let t = Target(id: "r-" + app.key, name: app.name, sub: version + " • " + app.repoName, remote: link, local: nil, added: true)
        if !extras.contains(where: { $0.id == t.id }) { extras.append(t) }
        picked.insert(t.id)
    }

    private func runBatch() async {
        message = nil
        let chosen = targets.filter { picked.contains($0.id) }
        let payload = dylibs.active
        guard !chosen.isEmpty, !payload.isEmpty else { return }
        running = true
        phases = [:]; progressDone = [:]; progressTotal = [:]

        let store = SignedBuildStore.shared
        let save: @Sendable (BatchJob) async throws -> Void = { job in
            let name = job.meta?.name ?? job.name
            let outcome = SignOutcome(ipaURL: job.output, name: name,
                                      bundleID: job.meta?.bundleID ?? "", version: job.meta?.version ?? "")
            let icon = job.meta?.iconPNG
            try await MainActor.run { _ = try store.add(outcome: outcome, icon: icon, certName: BatchInjector.unsignedTag) }
        }

        var jobs: [BatchJob] = []
        var nodes: [DAGNode] = []
        var owner: [String: String] = [:]          // node id → target id
        for t in chosen {
            let source: BatchJob.Source
            if let local = t.local { source = .local(local) }
            else if let link = t.remote, let url = URL(string: link) { source = .remote(url) }
            else { phases[t.id] = .failed("No download link."); continue }
            let job = BatchJob(id: t.id, name: t.name, source: source)
            jobs.append(job)
            let g = BatchInjector.graph(for: job, dylibs: payload, save: save)
            for n in g { owner[n.id] = t.id }
            progressTotal[t.id] = g.count
            phases[t.id] = .working("Waiting")
            nodes.append(contentsOf: g)
        }

        let ownerMap = owner
        let results = await DAGRunner.run(nodes, maxConcurrent: 4) { nodeID, state in
            Task { @MainActor in
                guard let tid = ownerMap[nodeID] else { return }
                switch state {
                case .running: phases[tid] = .working(BatchInjector.stageLabel(nodeID))
                case .done: progressDone[tid, default: 0] += 1
                case .failed(let m): phases[tid] = .failed(m)
                case .skipped: break
                }
            }
        }

        var okCount = 0
        for job in jobs {
            let saved = results[job.id + "/save"] == .done
            if saved { okCount += 1; phases[job.id] = .done }
            else if case .working = phases[job.id] ?? .waiting { phases[job.id] = .failed("Skipped after an earlier step failed.") }
            job.cleanup()
        }
        for t in chosen where t.id.hasPrefix("f-") { if let u = t.local { try? FileManager.default.removeItem(at: u) } }
        extras.removeAll { e in chosen.contains(where: { $0.id == e.id && e.id.hasPrefix("f-") }) }
        picked = picked.filter { id in targets.contains(where: { $0.id == id }) }
        running = false
        ActivityStore.shared.log("Batch", "injected \(payload.count) dylib\(payload.count == 1 ? "" : "s") into \(okCount) of \(chosen.count) app\(chosen.count == 1 ? "" : "s") (unsigned)")
    }

}


/// Search the apps in your repos and tick as many as you like.
struct BatchRepoPicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: RepoStore
    let onPick: ([AppEntry]) -> Void
    @State private var query = ""
    @State private var chosen: [String: AppEntry] = [:]

    private var results: [AppEntry] {
        let q: String = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        var out: [AppEntry] = []
        for app in store.apps where app.key.contains(q) {
            out.append(app)
            if out.count >= 40 { break }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            List {
                TextField("Search apps", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                if results.isEmpty {
                    Text("Type at least 2 letters. Your ticks are kept while you search again.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(results) { (app: AppEntry) in row(app) }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("Repo apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add \(chosen.count)") { onPick(Array(chosen.values)); dismiss() }.disabled(chosen.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ app: AppEntry) -> some View {
        let on: Bool = chosen[app.key] != nil
        return Button {
            if on { chosen[app.key] = nil } else { chosen[app.key] = app }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Color.dtAccent : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).foregroundStyle(.white).lineLimit(1)
                    Text(app.repoName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .disabled(app.current?.url?.absoluteString == nil)
    }
}
