import SwiftUI
import UniformTypeIdentifiers

/// Signer: pick an IPA (a build from Decrypt, an app from your repos, or a file), sign it with the active
/// certificate, and share or install the result.
struct SignerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: RepoStore
    @ObservedObject private var certs = CertificateStore.shared
    @ObservedObject private var builds = SignedStore.shared          // Uncrypt's server builds
    @ObservedObject private var results = SignedBuildStore.shared    // IPAs signed on this phone

    enum Source: String, CaseIterable, Identifiable {
        case decrypted = "Decrypted", repos = "Repos", files = "Files"
        var id: String { rawValue }
    }

    @State private var source: Source = .decrypted
    @State private var query = ""
    @State private var importing = false
    @State private var showCertificate = false
    @State private var customName = ""
    @State private var customBundleID = ""
    @State private var busy = false
    @State private var status = ""
    @State private var log: [String] = []
    @State private var error: String?
    @State private var lastResult: SignedBuild?

    var body: some View {
        NavigationStack {
            List {
                certificateSection
                Section {
                    Picker("Source", selection: $source) {
                        ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                sourceSection
                Section("Optional changes") {
                    TextField("App name", text: $customName)
                    TextField("Bundle ID", text: $customBundleID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if busy || !status.isEmpty || error != nil {
                    Section("Progress") {
                        if busy { HStack(spacing: 10) { ProgressView(); Text(status) } }
                        else if !status.isEmpty { Text(status) }
                        if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                        if !log.isEmpty {
                            Text(log.suffix(6).joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
                if let r = lastResult {
                    Section("Signed") { resultRow(r) }
                }
                if !results.entries.isEmpty {
                    Section("Signed on this phone") {
                        ForEach(results.entries.prefix(10)) { resultRow($0) }
                            .onDelete { idx in
                                let list = Array(results.entries.prefix(10))
                                for i in idx { results.delete(list[i]) }
                            }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("Signer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { Task { await signFile(url) } }
                else if case .failure(let e) = result { error = e.localizedDescription }
            }
            .sheet(isPresented: $showCertificate) { CertificateView() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: sections

    @ViewBuilder private var certificateSection: some View {
        Section("Certificate") {
            Button { showCertificate = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: certs.active == nil ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .foregroundStyle(certs.active == nil ? Color.orange : Color.dtAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(certs.active?.name ?? "No certificate").foregroundStyle(.white)
                        Text(certs.active == nil ? "Tap to import one" : "Tap to change").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var sourceSection: some View {
        switch source {
        case .decrypted:
            Section("Builds from Decrypt") {
                if builds.items.isEmpty {
                    Text("Nothing decrypted yet. Use Decrypt first.").foregroundStyle(.secondary)
                }
                ForEach(builds.items.prefix(30)) { e in
                    Button { Task { await signRemote(e.link, name: e.name) } } label: {
                        pickRow(e.name, e.version + " • " + e.bid)
                    }.disabled(busy || URL(string: e.link) == nil)
                }
            }
        case .repos:
            Section("Apps from your repos") {
                TextField("Search apps", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                let q = query.trimmingCharacters(in: .whitespaces).lowercased()
                let list = q.count < 2 ? [] : Array(store.apps.filter { $0.key.contains(q) }.prefix(25))
                if q.count < 2 { Text("Type at least 2 letters.").foregroundStyle(.secondary).font(.footnote) }
                ForEach(list) { app in
                    Button { Task { await signRemote(app.current?.downloadURL, name: app.name) } } label: {
                        pickRow(app.name, (app.current.map { "v" + $0.version } ?? "") + " • " + app.repoName)
                    }.disabled(busy || app.current?.downloadURL == nil)
                }
            }
        case .files:
            Section("A file on this phone") {
                Button { importing = true } label: {
                    Label("Choose an .ipa", systemImage: "doc.badge.plus").foregroundStyle(Color.dtAccent)
                }.disabled(busy)
            }
        }
    }

    private func pickRow(_ title: String, _ sub: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.white).lineLimit(1)
                Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text("Sign").font(.caption.weight(.bold)).foregroundStyle(Color.dtAccent)
        }
    }

    private func resultRow(_ r: SignedBuild) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).foregroundStyle(.white).lineLimit(1)
                Text(r.version + " • " + r.sizeString).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ShareLink(item: r.ipaURL) { Image(systemName: "square.and.arrow.up").foregroundStyle(Color.dtAccent) }
        }
    }

    // MARK: signing

    private func signRemote(_ link: String?, name: String) async {
        guard let link, let url = URL(string: link) else { error = "This app has no download link."; return }
        await run(name) { try await download(url, name: name) }
    }

    private func signFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.pathExtension.lowercased() == "ipa" else { error = "Choose an .ipa file."; return }
        let name = url.deletingPathExtension().lastPathComponent
        await run(name) {
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        }
    }

    private func run(_ name: String, fetch: () async throws -> URL) async {
        error = nil; lastResult = nil; log = []
        busy = true
        defer { busy = false }
        do {
            let material = try certs.activeMaterial()
            status = "Getting \(name)…"
            let ipa = try await fetch()
            defer { try? FileManager.default.removeItem(at: ipa) }
            status = "Signing \(name)…"
            var options = SignOptions()
            options.name = customName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : customName
            options.bundleID = customBundleID.trimmingCharacters(in: .whitespaces).isEmpty ? nil : customBundleID
            let outcome = try await Signer.signDetached(ipaURL: ipa, material: material, options: options, onLog: { line in
                Task { @MainActor in log.append(line) }
            })
            let meta = try? IPAMeta.read(ipa)
            let entry = try results.add(outcome: outcome, icon: meta?.iconPNG, certName: material.name)
            lastResult = entry
            status = "Signed \(entry.name)"
            ActivityStore.shared.log("Signer", "signed `" + entry.name + "` with " + material.name)
        } catch {
            status = ""
            self.error = error.localizedDescription
        }
    }

    private func download(_ url: URL, name: String) async throws -> URL {
        let (tmp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SignDownloadError(message: "Download failed (HTTP \(http.statusCode)).")
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}

struct SignDownloadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
