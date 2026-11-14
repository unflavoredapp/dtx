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
    /// false = sign on this phone, true = sign on the Decrypt.Team server
    @AppStorage("dt.sign.remote") private var remote = false

    struct Injected: Identifiable { let id = UUID(); let url: URL; var weak = false }

    private var chosen: AppVersion? { app.versions.first { $0.id == versionID } ?? app.current }

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                header
                switch step {
                case .page: AppHeroPage(app: app, chosen: chosen, versionID: $versionID, downloader: downloader)
                case .options:
                    SignOptionsPage(app: app, downloader: downloader, opts: $opts, name: $name, bundle: $bundle,
                                    version: $version, injected: $injected, iconPNG: $iconPNG, thin: $thin, remote: $remote, onChat: { store.pickedApp = nil; store.screen = nil; dismiss() }, onSign: { step = .run })
                case .run:
                    SignRunPage(app: app, downloader: downloader, opts: opts, name: name, bundle: bundle, version: version,
                                injected: injected, iconPNG: iconPNG, thin: thin, remote: remote, ipaLink: chosen?.url)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .onAppear {
            if versionID.isEmpty { versionID = app.current?.id ?? "" }
            DTXWallet.shared.track(app.bid, "view")
        }
        .overlay(alignment: .bottom) { if step == .page { bottomBar } }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            if step != .page {
                roundButton("chevron.left") { withAnimation { step = step == .run ? .options : .page } }
            }
            Spacer(minLength: 0)
            if step == .page {
                HStack(spacing: 7) {
                    repoIcon
                    Text(app.repoName.uppercased()).font(.system(size: 14, weight: .heavy)).tracking(3).lineLimit(1)
                }
            } else {
                HStack(spacing: 8) {
                    AppIconView(url: app.icon, name: app.name, size: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(app.name).font(.system(size: 12, weight: .bold)).lineLimit(1)
                        Text(app.bid).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.dtAccent).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            roundButton("xmark") { dismiss() }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(white: 0.11)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 1))
        .padding(.horizontal, 12).padding(.top, 5).padding(.bottom, 7)
    }

    /// The source's own icon; the lock badge stands in while it loads or when the source has none.
    private var repoIcon: some View {
        AsyncImage(url: store.meta[app.repoURL]?.icon) { phase in
            if let img = phase.image { img.resizable().scaledToFill() }
            else {
                Color.dtAccent.overlay(Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.dtOnAccent))
            }
        }
        .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func roundButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 36).background(Circle().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    // MARK: bottom bar (page step)

    private var bottomBar: some View {
        HStack(spacing: 6) {
            Button { startDownload() } label: { downloadLabel }.buttonStyle(.plain)
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Text("Made by ᴍƦᴢᴇꜰΛ").font(.system(size: 11, weight: .heavy)).foregroundStyle(Color(red: 0.94, green: 0.52, blue: 0.17))
                Text("Powered by Decrypt.Team").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color(red: 1.0, green: 0.30, blue: 0.30))
            }
            .lineLimit(1).minimumScaleFactor(0.6).layoutPriority(1)
            Spacer(minLength: 0)
            Button { goSign() } label: {
                VStack(spacing: 3) {
                    Image(systemName: "signature").font(.system(size: 18, weight: .medium))
                    Text("Sign IPA").font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(Color.dtAccent).frame(minWidth: 54, minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(white: 0.11)))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 1))
        .padding(.horizontal, 12).padding(.bottom, 5)
    }

    @ViewBuilder private var downloadLabel: some View {
        VStack(spacing: 3) {
            switch downloader.state {
            case .running:
                ZStack {
                    Circle().stroke(Color.dtAccent.opacity(0.25), lineWidth: 4)
                    Circle().trim(from: 0, to: max(0.03, downloader.progress)).stroke(Color.dtAccent, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                }
                .frame(width: 26, height: 26)
                Text("\(Int(downloader.progress * 100))%").font(.system(size: 11, weight: .bold))
            case .done:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 18, weight: .medium))
                Text("Ready").font(.system(size: 11, weight: .bold))
            default:
                Image(systemName: "arrow.down.circle").font(.system(size: 18, weight: .medium))
                Text("Download").font(.system(size: 11, weight: .bold))
            }
        }
        .foregroundStyle(Color.dtAccent).frame(minWidth: 54, minHeight: 44)
    }

    private func startDownload() {
        guard let u = chosen?.url else { return }
        DTXWallet.shared.track(app.bid, "download")
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
            VStack(alignment: .leading, spacing: 15) {
                top
                if !app.shots.isEmpty { shots }
                versions
                Color.clear.frame(height: 94)
            }
            .padding(.horizontal, 14).padding(.top, 5)
        }
        .scrollIndicators(.hidden)
    }

    private var top: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    AppIconView(url: app.icon, name: app.name, size: 53)
                        .shadow(color: Color.dtAccent.opacity(0.35), radius: 14)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.system(size: 15, weight: .heavy)).lineLimit(3)
                        if !app.developer.isEmpty { Text(app.developer).font(.system(size: 9, design: .monospaced)).foregroundStyle(Color.dtAccent).lineLimit(1) }
                        Text(app.bid).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.dtAccent.opacity(0.85)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                Text(app.repoName.uppercased() + " EDITION").font(.system(size: 9, weight: .heavy)).tracking(2).foregroundStyle(Color.dtAccent)
                if !app.subtitle.isEmpty {
                    Text(app.subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                stat(chosen.map { "v" + $0.version } ?? "-", "VERSION")
                stat(sizeText, "SIZE")
                stat(updatedText, "UPDATED")
            }
            .frame(width: 76)
        }
    }

    private func stat(_ v: String, _ k: String) -> some View {
        VStack(spacing: 3) {
            Text(v).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.dtAccent).lineLimit(1).minimumScaleFactor(0.6)
            Text(k).font(.system(size: 9, weight: .medium)).tracking(1.5).foregroundStyle(.secondary)
        }
    }

    private var shots: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("SCREENSHOTS")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(app.shots, id: \.self) { u in
                        AsyncImage(url: u) { p in
                            if let img = p.image { img.resizable().scaledToFill() } else { Color.white.opacity(0.06).overlay(ProgressView()) }
                        }
                        .frame(width: 102, height: 204).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(Color.white.opacity(0.1)))
                    }
                }
            }
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .heavy)).tracking(4).foregroundStyle(.secondary)
    }

    private var versions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(app.versions.count) Version\(app.versions.count == 1 ? "" : "s") Available")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary)
            ForEach(app.versions) { v in versionRow(v) }
            if downloader.state != .idle && downloader.state != .done { serverCard.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .animation(.easeInOut(duration: 0.3), value: downloader.state)
    }

    private func versionRow(_ v: AppVersion) -> some View {
        let on = v.id == versionID
        return Button { versionID = v.id } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(Color.dtAccent.opacity(0.3), lineWidth: 4)
                    if on && downloader.state == .running {
                        Circle().trim(from: 0, to: max(0.03, downloader.progress)).stroke(Color.dtAccent, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                    } else if on && downloader.state == .done {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.dtAccent).font(.system(size: 18))
                    } else {
                        Image(systemName: "arrow.down").foregroundStyle(Color.dtAccent).font(.system(size: 12, weight: .bold))
                    }
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("v" + v.version).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    Text(on ? statusText(v) : (v.size > 0 ? ByteCountFormatter.string(fromByteCount: v.size, countStyle: .file) : v.date))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if on { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.dtAccent) }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(on ? Color.dtAccent.opacity(0.10) : Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(on ? Color.dtAccent.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1))
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Server Download").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(downloader.progress * 100))%").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.dtAccent)
            }
            ProgressView(value: downloader.progress).tint(Color.dtAccent)
            HStack(spacing: 7) {
                Image(systemName: "arrow.down.square.fill").foregroundStyle(.secondary)
                Text(downloader.state == .running && downloader.received == 0 ? "Connecting…" : byteLine)
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack(spacing: 7) {
                Image(systemName: "globe").foregroundStyle(Color.dtAccent)
                Text(chosen?.url?.host ?? "").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.dtAccent)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private var byteLine: String {
        let r = ByteCountFormatter.string(fromByteCount: downloader.received, countStyle: .file)
        guard downloader.total > 0 else { return r }
        return r + " of " + ByteCountFormatter.string(fromByteCount: downloader.total, countStyle: .file)
    }
}

/// A certificate named after a device UDID is shown with its middle hidden: "00008110-••••••••E01E".
/// Any other name is shown as it is.
private func maskedUDID(_ name: String) -> String {
    let hex = name.filter { $0 != "-" }
    guard hex.count >= 24, hex.allSatisfy({ $0.isHexDigit }) else { return name }
    return String(name.prefix(8)) + "-••••••••" + String(name.suffix(4))
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
    @Binding var remote: Bool
    /// Leaves this page for the chat (the Ai-Decrypt tool).
    let onChat: () -> Void
    let onSign: () -> Void

    @ObservedObject private var certs = CertificateStore.shared
    @ObservedObject private var presets = SignPresetStore.shared
    @State private var showPresetName = false
    @State private var presetName = ""
    @State private var open: Set<String> = ["General"]
    @State private var toolSheet: ToolsHubView.HubSheet?
    @Environment(\.openURL) private var openURL
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
            VStack(alignment: .leading, spacing: 14) {
                if downloader.state != .done { downloadCard.transition(.opacity.combined(with: .move(edge: .top))) }
                title("SIGNING METHOD")
                certCard
                whereCard
                title("APP ICON")
                iconCard
                title("APP NAME · BUNDLE ID · VERSION")
                fieldsCard
                HStack { title("BUILD OPTIONS"); Spacer(); presetsMenu }
                group("General", "slider.horizontal.3", general)
                group("Strip Content", "scissors", strip, thinRow: true)
                group("Entitlement Scrubbers", "key.fill", scrubbers)
                plistGroup
                toolsGroup
                title("DYLIB INJECTION")
                injectCard
                Color.clear.frame(height: 92)
            }
            .animation(.easeInOut(duration: 0.3), value: downloader.state)
            .padding(.horizontal, 14).padding(.top, 5)
        }
        .scrollIndicators(.hidden)
        .overlay(alignment: .bottom) { signButton }
        .sheet(isPresented: $showCert) { CertificateView() }
        .sheet(item: $toolSheet) { s in ToolsHubView.sheetView(s) }
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
            Label("Presets", systemImage: "slider.horizontal.below.rectangle").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.dtAccent)
        }
    }

    /// Lives at the top of Strip Content.
    private var thinRow: some View {
        Toggle(isOn: $thin) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Thin to arm64 only").font(.system(size: 11))
                Text("Drops other architectures: about 30% smaller, A8+ devices").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .tint(Color.dtAccent).padding(.horizontal, 14).padding(.vertical, 7)
    }

    private func title(_ t: String) -> some View {
        Text(t).font(.system(size: 9, weight: .heavy)).tracking(4).foregroundStyle(.secondary).padding(.top, 3)
    }

    // MARK: cards

    private var downloadCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: downloader.state == .done ? "checkmark.circle.fill" : "arrow.down.circle.fill").foregroundStyle(Color.dtAccent)
                Text(downloader.state == .done ? "Downloaded \(app.name)" : "Downloading \(app.name)")
                    .font(.system(size: 12, weight: .bold)).lineLimit(1)
                Spacer()
                Text("\(Int(downloader.progress * 100))%").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.dtAccent)
            }
            ProgressView(value: downloader.progress).tint(Color.dtAccent)
            Text(downloader.state == .done ? "Everything is ready. Tap Sign IPA." : "Set your options now. Tap Sign IPA any time and it starts as soon as the download finishes.")
                .font(.system(size: 9)).foregroundStyle(.secondary)
            if case .failed(let m) = downloader.state { Text(m).font(.footnote).foregroundStyle(.red) }
        }
        .padding(14).background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private var certCard: some View {
        Button { showCert = true } label: {
            HStack(spacing: 12) {
                if certs.active == nil {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 20)).foregroundStyle(.orange)
                } else {
                    Image("CertificateIcon").resizable().scaledToFit().frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(certs.active == nil ? "NO CERTIFICATE" : "USING YOUR SAVED CERTIFICATE")
                        .font(.system(size: 9, weight: .heavy)).tracking(1.5).foregroundStyle(Color.dtAccent)
                    Text(certs.active.map { maskedUDID($0.name) } ?? "Add a .p12 and profile").font(.system(size: 15, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    Text(certDetail).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "gearshape.fill").font(.system(size: 14)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.1)))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.dtAccent.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.dtAccent.opacity(0.6), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    /// On this phone, or on our server (pinned workers, installs over the air from decrypt.team).
    private var whereCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            segRow("Sign on", ["This device", "Decrypt.Team"], remote ? 1 : 0) { remote = $0 == 1 }
            Text(whereNote).font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private var whereNote: String {
        guard remote else { return "Signed on this phone. Your certificate never leaves it." }
        var note = "A pinned worker on our server signs it and your phone installs it over the air from decrypt.team. "
        note += "Your certificate and its password are sent for this one job and deleted when it finishes."
        if let cost = DTXWallet.shared.hub?.prices?["sign"] { note += " Costs \(cost) DTX." }
        note += " Thin, dylib injection and Info.plist tweaks are on-device only."
        return note
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
            HStack(spacing: 12) {
                Group {
                    if let d = iconPNG, let ui = UIImage(data: d) { Image(uiImage: ui).resizable().scaledToFill() }
                    else { AppIconView(url: app.icon, name: app.name, size: 57) }
                }
                .frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Replace app icon").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    Text("PNG/JPEG — auto-resized to required sizes").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(12).background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private var fieldsCard: some View {
        VStack(spacing: 0) {
            field("textformat", "Name", $name)
            Divider().overlay(Color.white.opacity(0.08))
            field("shippingbox.fill", "Bundle ID", $bundle, mono: true)
            Divider().overlay(Color.white.opacity(0.08))
            field("number", "Version", $version, mono: true)
        }
        .padding(.vertical, 3).background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func field(_ icon: String, _ label: String, _ text: Binding<String>, mono: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.dtAccent)
                .frame(width: 37, height: 37).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.dtAccent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                TextField(label, text: text).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    // MARK: option groups

    private func count(_ flags: [Flag]) -> Int { flags.filter { opts[keyPath: $0.2] }.count }

    private func group(_ title: String, _ icon: String, _ flags: [Flag], thinRow showThin: Bool = false) -> some View {
        let isOpen = open.contains(title)
        let n = count(flags) + (showThin && thin ? 1 : 0)
        return VStack(spacing: 0) {
            groupHeader(title, icon, n, isOpen) { toggle(title) }
            if isOpen {
                if showThin {
                    Divider().overlay(Color.white.opacity(0.06))
                    thinRow
                }
                ForEach(0..<flags.count, id: \.self) { i in
                    Divider().overlay(Color.white.opacity(0.06))
                    flagRow(flags[i])
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func flagRow(_ f: Flag) -> some View {
        Toggle(isOn: Binding(get: { opts[keyPath: f.2] }, set: { opts[keyPath: f.2] = $0 })) {
            VStack(alignment: .leading, spacing: 1) {
                Text(f.0).font(.system(size: 11))
                if !f.1.isEmpty { Text(f.1).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }
        .tint(Color.dtAccent).padding(.horizontal, 14).padding(.vertical, 7)
    }

    private func groupHeader(_ title: String, _ icon: String, _ n: Int, _ isOpen: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.dtAccent)
                    .frame(width: 42, height: 42).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.dtAccent.opacity(0.14)))
                Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                Spacer()
                if n > 0 { Text("\(n)").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.dtAccent).padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.dtAccent.opacity(0.18))) }
                Image(systemName: isOpen ? "chevron.up" : "chevron.down").foregroundStyle(Color.dtAccent)
            }
            .padding(10)
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
                        Text(k).font(.system(size: 9, design: .monospaced)).foregroundStyle(Color.dtAccent)
                        Text(opts.plistSet[k] ?? "").font(.system(size: 9, design: .monospaced)).foregroundStyle(.white)
                        Spacer()
                        Button { opts.plistSet[k] = nil } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 7)
                }
                Divider().overlay(Color.white.opacity(0.06))
                HStack(spacing: 7) {
                    TextField("Key", text: $plistKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Value", text: $plistValue).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        let k = plistKey.trimmingCharacters(in: .whitespaces)
                        guard !k.isEmpty else { return }
                        opts.plistSet[k] = plistValue; plistKey = ""; plistValue = ""
                    } label: { Image(systemName: "plus.circle.fill").font(.system(size: 15)).foregroundStyle(Color.dtAccent) }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 9, design: .monospaced)).padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    // MARK: injection

    private var injectCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            segRow("Inject Path", ["@executable", "@rpath"], opts.injectPath == "@rpath" ? 1 : 0) { opts.injectPath = $0 == 1 ? "@rpath" : "@executable_path" }
            segRow("Inject Folder", ["/", "Frameworks/"], opts.injectFolder == "/" ? 0 : 1) { opts.injectFolder = $0 == 0 ? "/" : "Frameworks/" }
            Text(opts.injectPath + (opts.injectFolder == "/" ? "/" : "/Frameworks/") + "xxx.dylib")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.4)))
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
                VStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 16)).foregroundStyle(.secondary)
                    Text("Add library (.dylib)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 22)
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            }
            .buttonStyle(.plain)
        }
        .padding(14).background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func segRow(_ label: String, _ items: [String], _ sel: Int, _ pick: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).frame(width: 71, alignment: .leading)
            ForEach(0..<items.count, id: \.self) { i in
                Button { pick(i) } label: {
                    Text(items[i]).font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(sel == i ? Color.dtAccent : .secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(sel == i ? Color.dtAccent.opacity(0.14) : Color.black.opacity(0.35)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(sel == i ? Color.dtAccent : Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: tools

    /// Every tool from the Tools hub in one fold-out. Each tool opens right here.
    private var toolsGroup: some View {
        let isOpen = open.contains("Tools")
        return VStack(spacing: 0) {
            groupHeader("Tools", "wrench.and.screwdriver.fill", 0, isOpen) { toggle("Tools") }
            if isOpen {
                ForEach(ToolsHubView.catalog) { g in
                    Divider().overlay(Color.white.opacity(0.06))
                    Text(g.title.uppercased()).font(.system(size: 9, weight: .heavy)).tracking(2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                    ForEach(g.tools) { t in
                        Button { run(t) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: t.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dtAccent).frame(width: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                    Text(t.sub).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: isWeb(t) ? "arrow.up.right" : "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 7).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func isWeb(_ t: ToolsHubView.Tool) -> Bool { if case .web = t.action { return true } else { return false } }

    private func run(_ t: ToolsHubView.Tool) {
        ActivityStore.shared.log("Tools", "opened " + t.name)
        switch t.action {
        case .sheet(let s): toolSheet = s
        case .web(let u): if let url = URL(string: u) { openURL(url) }
        case .chat: onChat()
        }
    }

    private var signButton: some View {
        Button(action: onSign) {
            Label("Sign IPA", systemImage: "signature").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.dtOnAccent)
                .frame(maxWidth: .infinity).padding(.vertical, 15)
                .background(Capsule().fill(Color.dtAccent))
                .shadow(color: Color.dtAccent.opacity(0.35), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(certs.active == nil)
        .opacity(certs.active == nil ? 0.5 : 1)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 29, style: .continuous).fill(Color(white: 0.11)))
        .padding(.horizontal, 12).padding(.bottom, 5)
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
    let remote: Bool
    /// where the server fetches the IPA from
    let ipaLink: URL?

    struct Step: Identifiable {
        let id = UUID()
        var title: String
        var icon: String
        var state = 0               // 0 waiting, 1 running, 2 done, 3 failed
        var us: Int?                // how long the step took, in microseconds
    }

    @State private var steps: [Step]

    init(app: AppEntry, downloader: IPADownloader, opts: SignOptions, name: String, bundle: String, version: String,
         injected: [AppPageView.Injected], iconPNG: Data?, thin: Bool, remote: Bool, ipaLink: URL?) {
        self.app = app; self.downloader = downloader; self.opts = opts; self.name = name; self.bundle = bundle
        self.version = version; self.injected = injected; self.iconPNG = iconPNG; self.thin = thin
        self.remote = remote; self.ipaLink = ipaLink
        if remote {
            _steps = State(initialValue: [Step(title: "Send job to Decrypt.Team", icon: "paperplane"),
                                          Step(title: "Sign on server", icon: "server.rack"),
                                          Step(title: "Ready to install", icon: "checkmark.circle")])
            return
        }
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
    /// One line of the log: who wrote it (a signing thread, or the app itself), microseconds since signing began, the text.
    /// `worker` marks lines from the server: its pinned workers show as W1, W2… and the server itself as srv.
    struct LogLine { let thread: Int?; let us: Int; let text: String; var worker = false }
    @State private var log: [LogLine] = []
    @State private var began = Date()
    /// zsign's thread ids, numbered T0, T1… in the order they first speak
    @State private var threads: [String: Int] = [:]
    @State private var result: SignedBuild?
    /// set instead of `result` when the server signed it
    @State private var served: RemoteSign.Result?
    @State private var certUsed = ""
    @Environment(\.openURL) private var openURL
    @State private var error: String?
    @State private var started = false
    @ObservedObject private var installer = NativeInstaller.shared
    @State private var showSetup = false
    @State private var installError: String?
    @State private var totalUs = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SIGNER LOG").font(.system(size: 9, weight: .heavy)).tracking(4).foregroundStyle(.secondary)
                    Text(styledLog()).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    if !dagNodes.isEmpty { dagChart }
                    if result == nil && served == nil && error == nil { ProgressView().scaleEffect(0.7) }
                    if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
                    if let r = result { summary(name: r.name, bundleID: r.bundleID, version: r.version, cert: r.certName) }
                    else if let r = served { summary(name: r.name, bundleID: r.bundleId, version: r.version, cert: certUsed) }
                    Color.clear.frame(height: 96).id("end")
                }
                .padding(.horizontal, 15).padding(.top, 7)
            }
            .scrollIndicators(.hidden)
            .onChange(of: log.count) { _ in proxy.scrollTo("end", anchor: .bottom) }     // follows the log as it grows
            .onChange(of: served) { _ in DispatchQueue.main.async { withAnimation { proxy.scrollTo("end", anchor: .bottom) } } }
            .onChange(of: result) { _ in DispatchQueue.main.async { withAnimation { proxy.scrollTo("end", anchor: .bottom) } } }   // brings the summary rows into view
        }
        .overlay(alignment: .bottom) { bottomBar }
        .task { if !started { started = true; await run() } }
        .sheet(isPresented: $showSetup) { DeviceSetupView() }
        .alert("Couldn't install", isPresented: Binding(get: { installError != nil }, set: { if !$0 { installError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(installError ?? "") }
    }

    // MARK: log text

    private static let crying = Color(red: 0.25, green: 0.60, blue: 1.0)
    private static let thanks = Color(red: 1.0, green: 0.30, blue: 0.30)

    private static let stamp = try! NSRegularExpression(pattern: "@@T([0-9]+)@([0-9]+)@@")
    private static let threadColors: [Color] = [
        Color(red: 0.64, green: 0.95, blue: 0.42), Color(red: 0.35, green: 0.85, blue: 0.95), Color(red: 0.98, green: 0.84, blue: 0.28),
        Color(red: 1.0, green: 0.50, blue: 0.75), Color(red: 0.72, green: 0.60, blue: 1.0), Color(red: 0.98, green: 0.62, blue: 0.30),
    ]
    private static let decrypt = Color(red: 1.0, green: 0.30, blue: 0.30)
    private static let bar = Color(red: 0.98, green: 0.84, blue: 0.28)

    /// Lines the signer itself prints (not ones this view adds, like "Send job…" or "Fetching IPA…"). These get
    /// the old ">>> " dispatch marker back; everything else stays plain.
    private static let dagPrefixes = [
        "Unzip:", "Unzip OK!", "Signing:", "Signing OK!", "SignFolder:", "SignFile:", "AppName:", "BundleId:",
        "Version:", "TeamId:", "SubjectCN:", "ReadCache:", "Workers:", "Archive:", "Archive OK!", "Grand total",
        "[SmartArchive]", "[Archive]", "Checking:",
    ]
    private static func isDag(_ line: String) -> Bool { Self.dagPrefixes.contains { line.hasPrefix($0) } }

    /// Adds a line the app itself wrote.
    private func add(_ text: String, at: Date = Date()) {
        log.append(LogLine(thread: nil, us: max(0, Int(at.timeIntervalSince(began) * 1_000_000)), text: text))
    }

    /// Adds a line from the signer. Engine lines carry "@@T<thread>@<µs since 1970>@@"; that becomes the thread
    /// number and the time since signing began. The terminal colour codes and the ">>>" marker are dropped.
    private func addSigner(_ raw: String, arrived: Date) {
        var l = raw.replacingOccurrences(of: "\u{001B}?\\[[0-9;]*m", with: "", options: .regularExpression)
        var thread: Int?
        var at = arrived
        let ns = l as NSString
        if let m = Self.stamp.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: m.range(at: 1))
            if let n = threads[id] { thread = n } else { thread = threads.count; threads[id] = threads.count }
            if let us = Double(ns.substring(with: m.range(at: 2))) { at = Date(timeIntervalSince1970: us / 1_000_000) }
            l = Self.stamp.stringByReplacingMatches(in: l, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        }
        l = l.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix(">>>") { l = String(l.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
        guard !l.isEmpty else { return }
        log.append(LogLine(thread: thread, us: max(0, Int(at.timeIntervalSince(began) * 1_000_000)), text: l))
    }

    /// Lines the DAG-solver header replaces: the raw "Workers: N pinned…" line zsign prints once per job, right
    /// before it starts dispatching nested bundles to the chain.
    private static let workersDigits = try! NSRegularExpression(pattern: "([0-9]+)")

    /// The log as shown: thread, microseconds, then the line. When the signer has to make room for a bigger
    /// code signature, its three lines (no space, realloc, success) read as our own instead. The signer's own
    /// "Workers: N pinned…" line becomes a small DAG-solver header, matching the old layout: who's dispatching,
    /// to how many nodes. Every other line the signer itself prints gets its ">>> " marker back.
    private func styledLog() -> AttributedString {
        var out = AttributedString()
        var growing: Set<Int> = []          // per thread, so parallel files don't mix up their "Success"
        var wroteLine = false
        let totalNodes = log.reduce(0) { $0 + (($1.text.hasPrefix("SignFolder:")) ? 1 : 0) }

        func emit(_ piece: AttributedString) {
            if wroteLine { out.append(AttributedString("\n")) }
            out.append(piece)
            wroteLine = true
        }
        func dagHeader(_ text: String) -> AttributedString {
            var line = AttributedString("[")
            line.foregroundColor = Color.secondary
            var brand = AttributedString("Decrypt.Team"); brand.foregroundColor = Self.decrypt
            line.append(brand)
            var rest = AttributedString("] " + text); rest.foregroundColor = Color.secondary
            line.append(rest)
            return line
        }

        for entry in log {
            let line = entry.text
            let who = entry.thread ?? -1

            if line.hasPrefix("Workers:") {
                let ns = line as NSString
                let w = Self.workersDigits.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
                    .map { ns.substring(with: $0.range) } ?? "?"
                emit(dagHeader("DAG Solver: \(totalNodes) nodes | \(w) workers | lock-free queue"))
                emit(dagHeader("CPU Affinity: pinning \(w) workers, one per core"))
                continue
            }

            let label = entry.thread.map { (entry.worker ? "W" : "T") + "\($0)" } ?? (entry.worker ? "srv" : "app")
            var tag = AttributedString(label.padding(toLength: 4, withPad: " ", startingAt: 0))
            tag.foregroundColor = entry.thread.map { Self.threadColors[$0 % Self.threadColors.count] } ?? Color.secondary
            var time = AttributedString(String(format: "%8ldµs ", entry.us))
            time.foregroundColor = Color.secondary
            var piece: AttributedString
            let lower = line.lowercased()      // zsign's wording differs a little between the phone's build and the server's
            if lower.hasPrefix("no enough codesignature space") || lower.hasPrefix("can't find codesignature segment") {
                growing.insert(who)
                piece = AttributedString("Apple is ")
                var c = AttributedString("crying"); c.foregroundColor = Self.crying
                piece.append(c)
            } else if lower.hasPrefix("realloc codesignature space") {
                piece = AttributedString("Decrypting the space needed"); piece.foregroundColor = Self.thanks
            } else if growing.contains(who) && lower.hasPrefix("success") {
                growing.remove(who)
                piece = AttributedString("Thank you Decrypt.Team"); piece.foregroundColor = Self.thanks
            } else if Self.isDag(line) {
                var arrow = AttributedString(">>> "); arrow.foregroundColor = Color.secondary
                piece = arrow; piece.append(AttributedString(line))
            } else {
                piece = AttributedString(line)
            }
            var row = AttributedString()
            row.append(tag); row.append(time); row.append(piece)
            emit(row)
        }
        return out
    }

    /// One nested bundle's name and how long it took to sign, parsed from its "SignFolder: <path>, (<name>)" line.
    /// Ends at the next bundle's start, or at "Signing OK!" for the last one — so the chart only shows once the
    /// dispatch phase is actually finished and every duration is real.
    private struct DagNode: Identifiable { let id = UUID(); let name: String; let us: Int }

    private var dagNodes: [DagNode] {
        var starts: [(name: String, us: Int)] = []
        for entry in log where entry.text.hasPrefix("SignFolder:") {
            guard let open = entry.text.lastIndex(of: "("), let close = entry.text.lastIndex(of: ")"), open < close else { continue }
            starts.append((String(entry.text[entry.text.index(after: open)..<close]), entry.us))
        }
        guard starts.count > 1, let done = log.first(where: { $0.text.hasPrefix("Signing OK!") }) else { return [] }
        var ends = starts.dropFirst().map(\.us); ends.append(done.us)
        return zip(starts, ends).map { DagNode(name: $0.0.name, us: max(1, $0.1 - $0.0.us)) }
    }

    private var dagChart: some View {
        let nodes = dagNodes
        let maxUs = max(1, nodes.map(\.us).max() ?? 1)
        let threadCount = Set(log.compactMap { $0.text.hasPrefix("SignFolder:") ? $0.thread : nil }).count
        let spread = (nodes.map(\.us).max() ?? 0)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(nodes) { n in
                HStack(spacing: 6) {
                    Text(n.name).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .leading).lineLimit(1).truncationMode(.middle)
                    Rectangle().fill(Self.bar)
                        .frame(width: max(2, CGFloat(n.us) / CGFloat(maxUs) * 120), height: 7)
                    Text(String(format: "%.3fs", Double(n.us) / 1_000_000))
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            (Text("[").foregroundColor(.secondary) + Text("Decrypt.Team").foregroundColor(Self.decrypt)
                + Text("] DAG dispatch spread: \(spread)µs across \(max(1, threadCount)) threads").foregroundColor(.secondary))
                .font(.system(size: 9, design: .monospaced)).padding(.top, 2)
        }
    }

    // MARK: summary rows

    /// Plain log-style lines; the certificate line carries a small certificate icon and the days it has left.
    private func summary(name: String, bundleID: String, version: String, cert: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            summaryRow("App name", name)
            summaryRow("Bundle ID", bundleID)
            summaryRow("Version", version)
            summaryRow("Total time", totalTime)
            summaryRow("Certificate", maskedUDID(cert) + (daysLeft.map { " · " + $0 } ?? ""), icon: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryRow(_ label: String, _ value: String, icon: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if icon {
                Image("CertificateIcon").resizable().scaledToFit().frame(width: 11, height: 11)
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
            }
            (Text(label + ": ").foregroundColor(.secondary) + Text(value).foregroundColor(.white.opacity(0.85)))
                .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
        }
    }

    /// "241 days left", read from the active certificate's profile; nil when the expiry can't be read.
    private var daysLeft: String? {
        guard let c = CertificateStore.shared.active, let data = try? Data(contentsOf: c.provisionURL),
              let e = CertificateStore.profileInfo(data).expires else { return nil }
        let d = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: e)).day ?? 0
        if d < 0 { return "expired" }
        return d == 0 ? "expires today" : "\(d) day\(d == 1 ? "" : "s") left"
    }

    private var totalTime: String {
        "\(totalUs)µs" + (totalUs >= 1_000_000 ? String(format: " (%.2fs)", Double(totalUs) / 1_000_000) : "")
    }

    // MARK: bottom bar: Download, the Decrypt logo and credit, Install

    private var installing: Bool { installer.isActive && installer.job?.bundleID == result?.bundleID }

    private var bottomBar: some View {
        HStack(spacing: 6) {
            Group {
                if let r = result {
                    ShareLink(item: r.ipaURL) { barLabel("arrow.down.circle", "Download") }
                } else if let r = served, let u = URL(string: r.ipa) {
                    Button { openURL(u) } label: { barLabel("arrow.down.circle", "Download") }.buttonStyle(.plain)
                } else {
                    barLabel("arrow.down.circle", "Download").opacity(0.35)
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 3) {
                Image("Logo").resizable().scaledToFill()
                    .frame(width: 26, height: 26).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("Made by ᴍƦᴢᴇꜰΛ").font(.system(size: 11, weight: .heavy)).foregroundStyle(Color(red: 0.94, green: 0.52, blue: 0.17))
                Text("Powered by Decrypt.Team").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color(red: 1.0, green: 0.30, blue: 0.30))
            }
            .lineLimit(1).minimumScaleFactor(0.6).layoutPriority(1)
            Spacer(minLength: 0)
            Button { install() } label: {
                if installing { ProgressView().frame(minWidth: 54, minHeight: 44) }
                else { barLabel("antenna.radiowaves.left.and.right", "Install") }
            }
            .buttonStyle(.plain)
            .disabled((result == nil && served == nil) || installer.isActive)
            .opacity(result == nil && served == nil ? 0.35 : 1)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(white: 0.11)))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 1))
        .padding(.horizontal, 12).padding(.bottom, 5)
    }

    private func barLabel(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 18, weight: .medium))
            Text(text).font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(Color.dtAccent).frame(minWidth: 54, minHeight: 44)
    }

    /// Same as InstallSignedButton: native when selected, otherwise OTA over tetherless.dev.
    /// A server-signed build installs over the air from our domain.
    private func install() {
        if let r = served {
            if let u = URL(string: r.install) { openURL(u); ActivityStore.shared.log("Install", "installing `" + r.name + "` over the air") }
            return
        }
        guard let build = result else { return }
        if NativeInstaller.isSelected {
            Task {
                do {
                    try await NativeInstaller.shared.install(build)
                    ActivityStore.shared.log("Install", "installed `" + build.name + "` on this device")
                } catch is CancellationError {
                } catch { installError = error.localizedDescription }
            }
            return
        }
        Task {
            do {
                try await OTAInstaller.shared.install(build)
                ActivityStore.shared.log("Install", "OTA install for `" + build.name + "`")
            } catch is CancellationError {
            } catch { installError = error.localizedDescription }
        }
    }

    // MARK: work

    /// Each step writes its own line to the log as it starts, finishes or fails.
    private func mark(_ i: Int, _ state: Int, since t: Date? = nil) {
        steps[i].state = state
        if let t { steps[i].us = Int(Date().timeIntervalSince(t) * 1_000_000) }
        let name = steps[i].title
        switch state {
        case 1: add("▸ " + name + "…")
        case 2: add("✓ " + name + (steps[i].us.map { " · \($0)µs" } ?? ""))
        case 3: add("✗ " + name + " failed")
        default: break
        }
    }

    private func at(_ title: String) -> Int { steps.firstIndex { $0.title == title } ?? 0 }

    /// Server signing: send the job, then follow the server's log until it is done.
    private func runRemote() async {
        began = Date()
        var cur = 0
        var t = Date()
        do {
            cur = at("Send job to Decrypt.Team"); mark(cur, 1)
            guard let link = ipaLink else { throw SignDownloadError(message: "This app has no download link to send to the server.") }
            let material = try CertificateStore.shared.activeMaterial()
            certUsed = material.name
            if thin || !injected.isEmpty || !opts.plistSet.isEmpty { add("Note: thin, dylib injection and Info.plist tweaks only apply when signing on this device") }
            let newName = nonEmpty(name, unlessEqual: app.name), newBundle = nonEmpty(bundle, unlessEqual: app.bid)
            let v = version.trimmingCharacters(in: .whitespaces)
            var body: [String: Any] = [
                "ipaUrl": link.absoluteString,
                "p12": material.p12.base64EncodedString(), "provision": material.provision.base64EncodedString(), "password": material.password,
                "name": newName ?? app.name, "bundleId": newBundle ?? app.bid, "version": v.isEmpty ? (app.current?.version ?? "1.0") : v,
                "setName": newName != nil, "setBundleId": newBundle != nil,
                "setVersion": !v.isEmpty && !app.versions.contains { $0.version == v },
                "rmExtensions": opts.stripExtensions, "rmWatch": opts.stripWatchApps,
            ]
            if let iconPNG { body["icon"] = iconPNG.base64EncodedString() }
            let job = try await RemoteSign.start(body)
            // the server counts from the moment it accepted the job; this lines its clock up with ours
            let offset = Int(Date().timeIntervalSince(began) * 1_000_000)
            mark(cur, 2, since: t)

            cur = at("Sign on server"); t = Date(); mark(cur, 1)
            var next = 0
            while true {
                try await Task.sleep(nanoseconds: 350_000_000)
                let s = try await RemoteSign.status(job.id, since: next)
                for l in s.lines { log.append(LogLine(thread: l.w > 0 ? l.w : nil, us: offset + l.us, text: l.t, worker: true)) }
                next = s.next
                if s.state == "failed" { throw SignDownloadError(message: s.error ?? "The server could not sign this app.") }
                if s.state == "done", let r = s.result {
                    mark(cur, 2, since: t)
                    cur = at("Ready to install"); mark(cur, 2)
                    if let m = r.minutes { add("Install link is good for \(m) minutes") }
                    totalUs = Int(Date().timeIntervalSince(began) * 1_000_000)
                    served = r
                    ActivityStore.shared.log("Sign", "signed `" + r.name + "` on the server with " + maskedUDID(material.name))
                    DTXWallet.shared.track(app.bid, "download")
                    Task { await DTXWallet.shared.refresh() }
                    break
                }
            }
        } catch {
            mark(cur, 3)
            self.error = error.localizedDescription
        }
    }

    private func run() async {
        if remote { await runRemote(); return }
        began = Date()
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
                add("Thinned to arm64: saved " + ByteCountFormatter.string(fromByteCount: r.savedBytes, countStyle: .file))
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
                let arrived = Date()
                Task { @MainActor in addSigner(line, arrived: arrived) }
            }, threadStamps: true)
            mark(cur, 2, since: t)

            cur = at("Package signed IPA"); t = Date(); mark(cur, 1)
            let entry = try SignedBuildStore.shared.add(outcome: outcome, icon: iconPNG ?? meta?.iconPNG, certName: material.name)
            mark(cur, 2, since: t)

            cur = at("Ready to install"); mark(cur, 2)
            totalUs = Int(Date().timeIntervalSince(began) * 1_000_000)
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
