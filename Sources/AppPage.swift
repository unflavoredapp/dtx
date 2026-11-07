import SwiftUI
import PhotosUI
import UIKit

// MARK: - Download with live progress

@MainActor
final class IPADownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    enum State: Equatable { case idle, running, done, failed(String) }

    @Published var state: State = .idle
    @Published var progress: Double = 0
    @Published var received: Int64 = 0
    @Published var total: Int64 = 0
    private(set) var fileURL: URL?
    private(set) var sourceURL: URL?
    private var session: URLSession?

    func start(_ url: URL) {
        if sourceURL == url, state == .running || state == .done { return }
        cancel()
        sourceURL = url; fileURL = nil
        state = .running; progress = 0; received = 0; total = 0
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        s.downloadTask(with: url).resume()
    }

    func cancel() {
        session?.invalidateAndCancel()
        session = nil
        if state == .running { state = .idle }
    }

    /// Returns the downloaded file, waiting for the transfer to finish if it is still running.
    func finished() async throws -> URL {
        while true {
            switch state {
            case .done: if let f = fileURL { return f } else { throw SignDownloadError(message: "The download is missing.") }
            case .failed(let m): throw SignDownloadError(message: m)
            case .idle: throw SignDownloadError(message: "Nothing is downloading.")
            case .running: try await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            self.received = totalBytesWritten
            self.total = max(totalBytesExpectedToWrite, 0)
            self.progress = self.total > 0 ? Double(totalBytesWritten) / Double(self.total) : 0
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let http = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(http) else {
            Task { @MainActor in self.state = .failed("Download failed (HTTP \(http)).") }
            return
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            Task { @MainActor in self.fileURL = dest; self.progress = 1; self.state = .done }
        } catch {
            let m = error.localizedDescription
            Task { @MainActor in self.state = .failed(m) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        let m = error.localizedDescription
        Task { @MainActor in self.state = .failed(m) }
    }
}

// MARK: - The app page

/// Tapping an app: the app page, then the sign options, then the signing log and install.
struct AppPageView: View {
    let app: AppEntry

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: RepoStore
    @StateObject private var downloader = IPADownloader()
    @ObservedObject private var certs = CertificateStore.shared

    enum Step { case page, options, run }
    @State private var step = Step.page
    @State private var versionID = ""
    @State private var opts = SignOptions()
    @State private var name = ""
    @State private var bundle = ""
    @State private var version = ""
    @State private var injected: [Injected] = []
    @State private var iconPNG: Data?
    @State private var thin = false
    @State private var showTools = false

    struct Injected: Identifiable { let id = UUID(); let url: URL; var weak = false }

    private var chosen: AppVersion? { app.versions.first { $0.id == versionID } ?? app.current }

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                header
                switch step {
                case .page: AppHeroPage(app: app, chosen: chosen, versionID: $versionID, downloader: downloader, showTools: { showTools = true })
                case .options:
                    SignOptionsPage(app: app, downloader: downloader, opts: $opts, name: $name, bundle: $bundle,
                                    version: $version, injected: $injected, iconPNG: $iconPNG, thin: $thin, onSign: { step = .run })
                case .run:
                    SignRunPage(app: app, downloader: downloader, opts: opts, name: name, bundle: bundle, version: version,
                                injected: injected, iconPNG: iconPNG, thin: thin)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .onAppear { if versionID.isEmpty { versionID = app.current?.id ?? "" } }
        .overlay(alignment: .bottom) { if step == .page { bottomBar } }
        .sheet(isPresented: $showTools) {
            NavigationStack {
                AppDetailView(app: app)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { showTools = false } } }
            }
            .environmentObject(store)
            .preferredColorScheme(.dark)
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 12) {
            if step != .page {
                roundButton("chevron.left") { withAnimation { step = step == .run ? .options : .page } }
            }
            Spacer(minLength: 0)
            if step == .page {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.dtAccent).frame(width: 22, height: 26)
                        .overlay(Image(systemName: "lock.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.dtOnAccent))
                    Text(app.repoName.uppercased()).font(.system(size: 20, weight: .heavy)).tracking(3).lineLimit(1)
                }
            } else {
                HStack(spacing: 10) {
                    AppIconView(url: app.icon, name: app.name, size: 38)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(app.name).font(.system(size: 17, weight: .bold)).lineLimit(1)
                        Text(app.bid).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.dtAccent).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            roundButton("xmark") { dismiss() }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(white: 0.11)))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 1))
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 8)
    }

    private func roundButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 42, height: 42).background(Circle().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    // MARK: bottom bar (page step)

    private var bottomBar: some View {
        HStack {
            Button { startDownload() } label: { downloadLabel }.buttonStyle(.plain)
            Spacer()
            VStack(spacing: 2) {
                Text("UNCRYPT").font(.system(size: 14, weight: .heavy)).tracking(1.5).foregroundStyle(Color.dtAccent)
                Text("Powered by DECRYPT.TEAM").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { goSign() } label: {
                VStack(spacing: 4) {
                    Image(systemName: "signature").font(.system(size: 26, weight: .medium))
                    Text("Sign IPA").font(.system(size: 16, weight: .bold))
                }
                .foregroundStyle(Color.dtAccent).frame(minWidth: 92, minHeight: 60)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color(white: 0.11)))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 1))
        .padding(.horizontal, 14).padding(.bottom, 6)
    }

    @ViewBuilder private var downloadLabel: some View {
        VStack(spacing: 4) {
            switch downloader.state {
            case .running:
                ZStack {
                    Circle().stroke(Color.dtAccent.opacity(0.25), lineWidth: 4)
                    Circle().trim(from: 0, to: max(0.03, downloader.progress)).stroke(Color.dtAccent, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                }
                .frame(width: 30, height: 30)
                Text("\(Int(downloader.progress * 100))%").font(.system(size: 16, weight: .bold))
            case .done:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 26, weight: .medium))
                Text("Ready").font(.system(size: 16, weight: .bold))
            default:
                Image(systemName: "arrow.down.circle").font(.system(size: 26, weight: .medium))
                Text("Download").font(.system(size: 16, weight: .bold))
            }
        }
        .foregroundStyle(Color.dtAccent).frame(minWidth: 92, minHeight: 60)
    }

    private func startDownload() {
        guard let u = chosen?.url else { return }
        downloader.start(u)
    }

    private func goSign() {
        startDownload()
        if name.isEmpty { name = app.name }
        if bundle.isEmpty { bundle = app.bid }
        if version.isEmpty { version = chosen?.version ?? "" }
        withAnimation { step = .options }
    }
}

// MARK: - Page content

private struct AppHeroPage: View {
    let app: AppEntry
    let chosen: AppVersion?
    @Binding var versionID: String
    @ObservedObject var downloader: IPADownloader
    let showTools: () -> Void

    private var sizeText: String { (chosen?.size ?? 0) > 0 ? ByteCountFormatter.string(fromByteCount: chosen?.size ?? 0, countStyle: .file) : "-" }

    private var updatedText: String {
        guard let s = chosen?.date, !s.isEmpty else { return "-" }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        if let d = iso.date(from: s) ?? plain.date(from: s) ?? plain.date(from: s + "T00:00:00Z") {
            return RelativeDateTimeFormatter().localizedString(for: min(d, Date()), relativeTo: Date())
        }
        return s
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                top
                if !app.shots.isEmpty { shots }
                versions
                toolsRow
                Color.clear.frame(height: 110)
            }
            .padding(.horizontal, 16).padding(.top, 6)
        }
        .scrollIndicators(.hidden)
    }

    private var top: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    AppIconView(url: app.icon, name: app.name, size: 78)
                        .shadow(color: Color.dtAccent.opacity(0.35), radius: 14)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.system(size: 22, weight: .heavy)).lineLimit(3)
                        if !app.developer.isEmpty { Text(app.developer).font(.system(size: 14, design: .monospaced)).foregroundStyle(Color.dtAccent).lineLimit(1) }
                        Text(app.bid).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.dtAccent.opacity(0.85)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                Text(app.repoName.uppercased() + " EDITION").font(.system(size: 14, weight: .heavy)).tracking(2).foregroundStyle(Color.dtAccent)
                if !app.subtitle.isEmpty {
                    Text(app.subtitle).font(.system(size: 15)).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 14) {
                stat(chosen.map { "v" + $0.version } ?? "-", "VERSION")
                stat(sizeText, "SIZE")
                stat(updatedText, "UPDATED")
            }
            .frame(width: 104)
        }
    }

    private func stat(_ v: String, _ k: String) -> some View {
        VStack(spacing: 3) {
            Text(v).font(.system(size: 17, weight: .bold)).foregroundStyle(Color.dtAccent).lineLimit(1).minimumScaleFactor(0.6)
            Text(k).font(.system(size: 11, weight: .medium)).tracking(1.5).foregroundStyle(.secondary)
        }
    }

    private var shots: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("SCREENSHOTS")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(app.shots, id: \.self) { u in
                        AsyncImage(url: u) { p in
                            if let img = p.image { img.resizable().scaledToFill() } else { Color.white.opacity(0.06).overlay(ProgressView()) }
                        }
                        .frame(width: 170, height: 340).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.1)))
                    }
                }
            }
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 16, weight: .heavy)).tracking(4).foregroundStyle(.secondary)
    }

    private var versions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(app.versions.count) Version\(app.versions.count == 1 ? "" : "s") Available")
                .font(.system(size: 19, weight: .bold)).foregroundStyle(.secondary)
            ForEach(app.versions) { v in versionRow(v) }
            if downloader.state != .idle { serverCard }
        }
    }

    private func versionRow(_ v: AppVersion) -> some View {
        let on = v.id == versionID
        return Button { versionID = v.id } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Color.dtAccent.opacity(0.3), lineWidth: 4)
                    if on && downloader.state == .running {
                        Circle().trim(from: 0, to: max(0.03, downloader.progress)).stroke(Color.dtAccent, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                    } else if on && downloader.state == .done {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.dtAccent).font(.system(size: 26))
                    } else {
                        Image(systemName: "arrow.down").foregroundStyle(Color.dtAccent).font(.system(size: 17, weight: .bold))
                    }
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("v" + v.version).font(.system(size: 21, weight: .bold)).foregroundStyle(.white)
                    Text(on ? statusText(v) : (v.size > 0 ? ByteCountFormatter.string(fromByteCount: v.size, countStyle: .file) : v.date))
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                }
                Spacer()
                if on { Image(systemName: "checkmark").font(.system(size: 22, weight: .bold)).foregroundStyle(Color.dtAccent) }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(on ? Color.dtAccent.opacity(0.10) : Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(on ? Color.dtAccent.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func statusText(_ v: AppVersion) -> String {
        switch downloader.state {
        case .running: return "Downloading \(Int(downloader.progress * 100))%"
        case .done: return "Downloaded · ready to sign"
        case .failed(let m): return m
        case .idle: return v.size > 0 ? ByteCountFormatter.string(fromByteCount: v.size, countStyle: .file) : "Tap Download or Sign IPA"
        }
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Server Download").font(.system(size: 17, weight: .bold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(downloader.progress * 100))%").font(.system(size: 17, weight: .bold)).foregroundStyle(Color.dtAccent)
            }
            ProgressView(value: downloader.progress).tint(Color.dtAccent)
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.square.fill").foregroundStyle(.secondary)
                Text(downloader.state == .running && downloader.received == 0 ? "Connecting…" : byteLine)
                    .font(.system(size: 14, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "globe").foregroundStyle(Color.dtAccent)
                Text(chosen?.url?.host ?? "").font(.system(size: 15, design: .monospaced)).foregroundStyle(Color.dtAccent)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private var byteLine: String {
        let r = ByteCountFormatter.string(fromByteCount: downloader.received, countStyle: .file)
        guard downloader.total > 0 else { return r }
        return r + " of " + ByteCountFormatter.string(fromByteCount: downloader.total, countStyle: .file)
    }

    private var toolsRow: some View {
        Button(action: showTools) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars").foregroundStyle(Color.dtAccent).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dylibs, frameworks & tools").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    Text("Saved libraries, Decrypt & Inject, IPA tools").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(14).card()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sign options

private struct SignOptionsPage: View {
    let app: AppEntry
    @ObservedObject var downloader: IPADownloader
    @Binding var opts: SignOptions
    @Binding var name: String
    @Binding var bundle: String
    @Binding var version: String
    @Binding var injected: [AppPageView.Injected]
    @Binding var iconPNG: Data?
    @Binding var thin: Bool
    let onSign: () -> Void

    @ObservedObject private var certs = CertificateStore.shared
    @ObservedObject private var presets = SignPresetStore.shared
    @State private var showPresetName = false
    @State private var presetName = ""
    @State private var open: Set<String> = ["General"]
    @State private var photo: PhotosPickerItem?
    @State private var showCert = false
    @State private var importing = false
    @State private var plistKey = ""
    @State private var plistValue = ""

    private typealias Flag = (String, String, WritableKeyPath<SignOptions, Bool>)
    private let general: [Flag] = [
        ("Disable file sharing", "Hides the app from Files", \.disableFileSharing),
        ("Force portrait", "Lock the orientation", \.forcePortrait),
        ("Skip iPad", "Drop iPad support", \.skipIPad),
        ("Disable ATS", "Allow plain http", \.disableATS),
    ]
    private let strip: [Flag] = [
        ("Strip SC_Info", "Remove store DRM files", \.stripSCInfo),
        ("Strip privacy manifests", "", \.stripPrivacyManifests),
        ("Strip watch apps", "", \.stripWatchApps),
        ("Strip extensions", "Plugins and widgets", \.stripExtensions),
        ("Remove URL schemes", "", \.removeURLSchemes),
        ("Strip bitcode", "", \.stripBitcode),
        ("Strip debug symbols", "", \.stripDebugSymbols),
    ]
    private let scrubbers: [Flag] = [
        ("Auto-fix entitlements", "Drop what the profile doesn't grant", \.autoFixEntitlements),
        ("Disable push", "", \.disablePush),
        ("Disable app groups", "", \.disableAppGroups),
        ("Disable iCloud", "", \.disableiCloud),
        ("Disable Siri", "", \.disableSiri),
        ("Disable background modes", "", \.disableBackgroundModes),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                downloadCard
                title("SIGNING METHOD")
                certCard
                title("APP ICON")
                iconCard
                title("APP NAME · BUNDLE ID · VERSION")
                fieldsCard
                HStack { title("BUILD OPTIONS"); Spacer(); presetsMenu }
                thinCard
                group("General", "slider.horizontal.3", general)
                group("Strip Content", "scissors", strip)
                group("Entitlement Scrubbers", "key.fill", scrubbers)
                plistGroup
                title("DYLIB INJECTION")
                injectCard
                Color.clear.frame(height: 90)
            }
            .padding(.horizontal, 16).padding(.top, 6)
        }
        .scrollIndicators(.hidden)
        .overlay(alignment: .bottom) { signButton }
        .sheet(isPresented: $showCert) { CertificateView() }
        .alert("Save preset", isPresented: $showPresetName) {
            TextField("Name", text: $presetName)
            Button("Save") {
                let n = presetName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { presets.save(name: n, from: opts, thin: thin) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .filePicker(isPresented: $importing, types: [.data], multiple: true) { urls in
            for u in urls { injected.append(.init(url: u)) }
        }
        .onChange(of: photo) { item in
            guard let item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self), let ui = UIImage(data: d) { iconPNG = ui.pngData() }
            }
        }
    }

    private var presetsMenu: some View {
        Menu {
            Button { presetName = ""; showPresetName = true } label: { Label("Save these options as a preset…", systemImage: "plus") }
            ForEach(presets.items) { p in
                Button(p.name) { presets.apply(p, to: &opts); thin = p.thin }
            }
            if !presets.items.isEmpty {
                Menu("Delete a preset") { ForEach(presets.items) { p in Button(p.name, role: .destructive) { presets.delete(p) } } }
            }
        } label: {
            Label("Presets", systemImage: "slider.horizontal.below.rectangle").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.dtAccent)
        }
    }

    private var thinCard: some View {
        Toggle(isOn: $thin) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Thin to arm64 only").font(.system(size: 17, weight: .semibold))
                Text("Drops other architectures: about 30% smaller, A8+ devices").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .tint(Color.dtAccent).padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func title(_ t: String) -> some View {
        Text(t).font(.system(size: 14, weight: .heavy)).tracking(4).foregroundStyle(.secondary).padding(.top, 4)
    }

    // MARK: cards

    private var downloadCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: downloader.state == .done ? "checkmark.circle.fill" : "arrow.down.circle.fill").foregroundStyle(Color.dtAccent)
                Text(downloader.state == .done ? "Downloaded \(app.name)" : "Downloading \(app.name)")
                    .font(.system(size: 17, weight: .bold)).lineLimit(1)
                Spacer()
                Text("\(Int(downloader.progress * 100))%").font(.system(size: 17, weight: .bold)).foregroundStyle(Color.dtAccent)
            }
            ProgressView(value: downloader.progress).tint(Color.dtAccent)
            Text(downloader.state == .done ? "Everything is ready. Tap Sign IPA." : "Set your options now. Tap Sign IPA any time and it starts as soon as the download finishes.")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            if case .failed(let m) = downloader.state { Text(m).font(.footnote).foregroundStyle(.red) }
        }
        .padding(16).background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private var certCard: some View {
        Button { showCert = true } label: {
            HStack(spacing: 14) {
                Image(systemName: certs.active == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 30)).foregroundStyle(certs.active == nil ? .orange : Color.dtAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(certs.active == nil ? "NO CERTIFICATE" : "USING YOUR SAVED CERTIFICATE")
                        .font(.system(size: 11, weight: .heavy)).tracking(1.5).foregroundStyle(Color.dtAccent)
                    Text(certs.active?.name ?? "Add a .p12 and profile").font(.system(size: 22, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    Text(certDetail).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "gearshape.fill").font(.system(size: 20)).foregroundStyle(.white)
                    .frame(width: 52, height: 52).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.1)))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.dtAccent.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.dtAccent.opacity(0.6), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private var certDetail: String {
        guard let c = certs.active, let data = try? Data(contentsOf: c.provisionURL) else { return "Tap to import one" }
        let p = CertificateStore.profileInfo(data)
        var parts: [String] = []
        if let t = p.team { parts.append(t) }
        if let e = p.expires { parts.append("Expires " + e.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }

    private var iconCard: some View {
        PhotosPicker(selection: $photo, matching: .images) {
            HStack(spacing: 14) {
                Group {
                    if let d = iconPNG, let ui = UIImage(data: d) { Image(uiImage: ui).resizable().scaledToFill() }
                    else { AppIconView(url: app.icon, name: app.name, size: 84) }
                }
                .frame(width: 84, height: 84).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Replace app icon").font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                    Text("PNG/JPEG — auto-resized to required sizes").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(14).background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private var fieldsCard: some View {
        VStack(spacing: 0) {
            field("Aa", "Name", $name)
            Divider().overlay(Color.white.opacity(0.08))
            field("shippingbox.fill", "Bundle ID", $bundle, mono: true)
            Divider().overlay(Color.white.opacity(0.08))
            field("number", "Version", $version, mono: true)
        }
        .padding(.vertical, 4).background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func field(_ icon: String, _ label: String, _ text: Binding<String>, mono: Bool = false) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 17, weight: .bold)).foregroundStyle(Color.dtAccent)
                .frame(width: 44, height: 44).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.dtAccent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                TextField(label, text: text).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(mono ? .system(size: 17, design: .monospaced) : .system(size: 17))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: option groups

    private func count(_ flags: [Flag]) -> Int { flags.filter { opts[keyPath: $0.2] }.count }

    private func group(_ title: String, _ icon: String, _ flags: [Flag]) -> some View {
        let isOpen = open.contains(title)
        let n = count(flags)
        return VStack(spacing: 0) {
            groupHeader(title, icon, n, isOpen) { toggle(title) }
            if isOpen {
                ForEach(0..<flags.count, id: \.self) { i in
                    Divider().overlay(Color.white.opacity(0.06))
                    flagRow(flags[i])
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func flagRow(_ f: Flag) -> some View {
        Toggle(isOn: Binding(get: { opts[keyPath: f.2] }, set: { opts[keyPath: f.2] = $0 })) {
            VStack(alignment: .leading, spacing: 1) {
                Text(f.0).font(.system(size: 16))
                if !f.1.isEmpty { Text(f.1).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }
        .tint(Color.dtAccent).padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func groupHeader(_ title: String, _ icon: String, _ n: Int, _ isOpen: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 18, weight: .bold)).foregroundStyle(Color.dtAccent)
                    .frame(width: 50, height: 50).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.dtAccent.opacity(0.14)))
                Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                Spacer()
                if n > 0 { Text("\(n)").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.dtAccent).padding(.horizontal, 10).padding(.vertical, 4).background(Capsule().fill(Color.dtAccent.opacity(0.18))) }
                Image(systemName: isOpen ? "chevron.up" : "chevron.down").foregroundStyle(Color.dtAccent)
            }
            .padding(12)
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ t: String) {
        withAnimation(.easeInOut(duration: 0.2)) { if open.contains(t) { open.remove(t) } else { open.insert(t) } }
    }

    private var plistGroup: some View {
        let isOpen = open.contains("Info.plist Tweaks")
        return VStack(spacing: 0) {
            groupHeader("Info.plist Tweaks", "doc.fill", opts.plistSet.count, isOpen) { toggle("Info.plist Tweaks") }
            if isOpen {
                ForEach(opts.plistSet.keys.sorted(), id: \.self) { k in
                    Divider().overlay(Color.white.opacity(0.06))
                    HStack {
                        Text(k).font(.system(size: 14, design: .monospaced)).foregroundStyle(Color.dtAccent)
                        Text(opts.plistSet[k] ?? "").font(.system(size: 14, design: .monospaced)).foregroundStyle(.white)
                        Spacer()
                        Button { opts.plistSet[k] = nil } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                Divider().overlay(Color.white.opacity(0.06))
                HStack(spacing: 8) {
                    TextField("Key", text: $plistKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Value", text: $plistValue).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        let k = plistKey.trimmingCharacters(in: .whitespaces)
                        guard !k.isEmpty else { return }
                        opts.plistSet[k] = plistValue; plistKey = ""; plistValue = ""
                    } label: { Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundStyle(Color.dtAccent) }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 14, design: .monospaced)).padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    // MARK: injection

    private var injectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            segRow("Inject Path", ["@executable", "@rpath"], opts.injectPath == "@rpath" ? 1 : 0) { opts.injectPath = $0 == 1 ? "@rpath" : "@executable_path" }
            segRow("Inject Folder", ["/", "Frameworks/"], opts.injectFolder == "/" ? 0 : 1) { opts.injectFolder = $0 == 0 ? "/" : "Frameworks/" }
            Text(opts.injectPath + (opts.injectFolder == "/" ? "/" : "/Frameworks/") + "xxx.dylib")
                .font(.system(size: 16, design: .monospaced)).foregroundStyle(.secondary)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.4)))
            ForEach($injected) { $d in
                HStack {
                    Image(systemName: "shippingbox.fill").foregroundStyle(Color.dtAccent)
                    Text(d.url.lastPathComponent).lineLimit(1)
                    Spacer()
                    Toggle("Weak", isOn: $d.weak).labelsHidden().tint(Color.dtAccent)
                    Text("weak").font(.caption).foregroundStyle(.secondary)
                    Button { injected.removeAll { $0.id == d.id } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }.buttonStyle(.plain)
                }
            }
            Button { importing = true } label: {
                VStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 24)).foregroundStyle(.secondary)
                    Text("Add library (.dylib)").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 26)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            }
            .buttonStyle(.plain)
        }
        .padding(16).background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func segRow(_ label: String, _ items: [String], _ sel: Int, _ pick: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 16)).frame(width: 84, alignment: .leading)
            ForEach(0..<items.count, id: \.self) { i in
                Button { pick(i) } label: {
                    Text(items[i]).font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(sel == i ? Color.dtAccent : .secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(sel == i ? Color.dtAccent.opacity(0.14) : Color.black.opacity(0.35)))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(sel == i ? Color.dtAccent : Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var signButton: some View {
        Button(action: onSign) {
            Label("Sign IPA", systemImage: "signature").font(.system(size: 20, weight: .bold)).foregroundStyle(Color.dtOnAccent)
                .frame(maxWidth: .infinity).padding(.vertical, 18)
                .background(Capsule().fill(Color.dtAccent))
                .shadow(color: Color.dtAccent.opacity(0.35), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(certs.active == nil)
        .opacity(certs.active == nil ? 0.5 : 1)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 34, style: .continuous).fill(Color(white: 0.11)))
        .padding(.horizontal, 14).padding(.bottom, 6)
    }
}

// MARK: - Signing log

private struct SignRunPage: View {
    let app: AppEntry
    @ObservedObject var downloader: IPADownloader
    let opts: SignOptions
    let name: String
    let bundle: String
    let version: String
    let injected: [AppPageView.Injected]
    let iconPNG: Data?
    let thin: Bool

    struct Step: Identifiable {
        let id = UUID()
        var title: String
        var icon: String
        var state = 0               // 0 waiting, 1 running, 2 done, 3 failed
        var ms: Int?
    }

    @State private var steps: [Step]

    init(app: AppEntry, downloader: IPADownloader, opts: SignOptions, name: String, bundle: String, version: String,
         injected: [AppPageView.Injected], iconPNG: Data?, thin: Bool) {
        self.app = app; self.downloader = downloader; self.opts = opts; self.name = name; self.bundle = bundle
        self.version = version; self.injected = injected; self.iconPNG = iconPNG; self.thin = thin
        var s = [
            Step(title: "Download IPA", icon: "arrow.down.circle"),
            Step(title: "Read app bundle", icon: "doc.text.magnifyingglass"),
        ]
        if thin { s.append(Step(title: "Thin to arm64", icon: "scissors")) }
        s += [Step(title: "Sign app bundle", icon: "signature"),
              Step(title: "Package signed IPA", icon: "shippingbox"),
              Step(title: "Ready to install", icon: "checkmark.circle")]
        _steps = State(initialValue: s)
    }
    @State private var log: [String] = []
    @State private var showLog = false
    @State private var result: SignedBuild?
    @State private var error: String?
    @State private var started = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(steps) { s in row(s) }
                if let error { Text(error).font(.system(size: 14)).foregroundStyle(.red).padding(.top, 8) }
                if let r = result { resultCard(r) }
                if !log.isEmpty { logCard }
                Color.clear.frame(height: 40)
            }
            .padding(.horizontal, 18).padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .task { if !started { started = true; await run() } }
    }

    private func row(_ s: Step) -> some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: s.icon).font(.system(size: 24)).foregroundStyle(.white.opacity(0.8)).frame(width: 40, height: 40)
                badge(s.state)
            }
            Text(s.title).font(.system(size: 19)).foregroundStyle(s.state == 0 ? Color.secondary : Color.white)
            Spacer()
            if let ms = s.ms { Text("\(ms)ms").font(.system(size: 14, design: .monospaced)).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private func badge(_ state: Int) -> some View {
        switch state {
        case 1: ProgressView().scaleEffect(0.6).frame(width: 18, height: 18)
        case 2: Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(.green).background(Circle().fill(.black))
        case 3: Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundStyle(.red).background(Circle().fill(.black))
        default: EmptyView()
        }
    }

    private func resultCard(_ r: SignedBuild) -> some View {
        VStack(spacing: 14) {
            Text(r.name).font(.system(size: 22, weight: .bold))
            Text("v" + r.version + " · " + r.sizeString + " · " + r.certName).font(.system(size: 14)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                InstallSignedButton(build: r)
                ShareLink(item: r.ipaURL) {
                    Label("Share", systemImage: "square.and.arrow.up").font(.system(size: 16, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10).background(Capsule().fill(Color.white.opacity(0.1)))
                }
            }
        }
        .frame(maxWidth: .infinity).padding(18)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.white.opacity(0.07)))
        .padding(.top, 14)
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation { showLog.toggle() } } label: {
                HStack { Text("Signer log").font(.system(size: 15, weight: .semibold)); Spacer(); Image(systemName: showLog ? "chevron.up" : "chevron.down") }
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if showLog {
                Text(log.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.top, 14)
    }

    // MARK: work

    private func mark(_ i: Int, _ state: Int, since t: Date? = nil) {
        steps[i].state = state
        if let t { steps[i].ms = Int(Date().timeIntervalSince(t) * 1000) }
    }

    private func at(_ title: String) -> Int { steps.firstIndex { $0.title == title } ?? 0 }

    private func run() async {
        var cur = 0
        var t = Date()
        do {
            cur = at("Download IPA"); mark(cur, 1)
            var ipa = try await downloader.finished()
            mark(cur, 2, since: t)

            cur = at("Read app bundle"); t = Date(); mark(cur, 1)
            let meta = try? IPAMeta.read(ipa)
            let material = try CertificateStore.shared.activeMaterial()
            mark(cur, 2, since: t)

            if thin {
                cur = at("Thin to arm64"); t = Date(); mark(cur, 1)
                let source = ipa
                let r = try await Task.detached { try IPAThinner.thin(source) }.value
                ipa = r.url
                log.append("Thinned to arm64: saved " + ByteCountFormatter.string(fromByteCount: r.savedBytes, countStyle: .file))
                mark(cur, 2, since: t)
            }

            cur = at("Sign app bundle"); t = Date(); mark(cur, 1)
            var o = opts
            o.name = nonEmpty(name, unlessEqual: app.name)
            o.bundleID = nonEmpty(bundle, unlessEqual: app.bid)
            o.version = nonEmpty(version, unlessEqual: nil)
            o.iconPNG = iconPNG
            o.injectDylibs = injected.map { (url: $0.url, weak: $0.weak) }
            let outcome = try await Signer.signDetached(ipaURL: ipa, material: material, options: o, onLog: { line in
                Task { @MainActor in log.append(line) }
            })
            mark(cur, 2, since: t)

            cur = at("Package signed IPA"); t = Date(); mark(cur, 1)
            let entry = try SignedBuildStore.shared.add(outcome: outcome, icon: iconPNG ?? meta?.iconPNG, certName: material.name)
            mark(cur, 2, since: t)

            cur = at("Ready to install"); mark(cur, 2)
            result = entry
            ActivityStore.shared.log("Sign", "signed `" + entry.name + "` with " + material.name)
        } catch {
            mark(cur, 3)
            self.error = error.localizedDescription
        }
    }

    private func nonEmpty(_ s: String, unlessEqual same: String?) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t == same ? nil : t
    }
}
