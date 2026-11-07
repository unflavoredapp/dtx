import SwiftUI

/// Signed: every build you made on this phone, newest first. The arrow installs, shares or copies its link.
struct SignedView: View {
    @EnvironmentObject var store: RepoStore
    @ObservedObject private var signed = SignedStore.shared
    @ObservedObject private var phoneBuilds = SignedBuildStore.shared   // IPAs signed on this phone

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(phoneBuilds.entries) { b in
                        HStack(spacing: 14) {
                            AppIconView(url: b.iconURL, name: b.name, size: 64)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(b.name).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                Text([b.version.isEmpty ? nil : b.version, b.bundleID].compactMap { $0 }.joined(separator: " • "))
                                    .font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                RowPill(text: (b.certName == BatchInjector.unsignedTag ? "Injected · unsigned" : "Signed on phone") + (b.sizeString.isEmpty ? "" : " · " + b.sizeString))
                            }
                            Spacer(minLength: 0)
                            InstallSignedButton(build: b)
                            ShareLink(item: b.ipaURL) { Image(systemName: "square.and.arrow.up").foregroundStyle(Color.dtAccent) }
                        }
                        .padding(.vertical, 12)
                        Divider().overlay(Color.dtLine)
                    }
                    if signed.items.isEmpty && phoneBuilds.entries.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: UIImage(systemName: "signature") != nil ? "signature" : "pencil.and.scribble").font(.system(size: 44)).foregroundStyle(Color.dtAccent)
                            Text("Nothing signed yet").font(.title3.weight(.semibold))
                            Text("Decrypt and inject an app and its build shows up here.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Decrypt & Inject") { store.showQuickBuild = true }.buttonStyle(AccentButtonStyle()).padding(.top, 6)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 60).padding(.horizontal, 20)
                    }
                    ForEach(signed.items) { e in
                        row(e)
                        Divider().overlay(Color.dtLine)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 24)
            }
            .background(AppBackground())
            .withTopBar(.signed, title: "Signed", strip: "\(signed.items.count + phoneBuilds.entries.count) App\(signed.items.count + phoneBuilds.entries.count == 1 ? "" : "s")", actions: [.lock])
        }
    }

    private func row(_ e: SignedEntry) -> some View {
        HStack(spacing: 14) {
            AppIconView(url: e.icon.flatMap { URL(string: $0) }, name: e.name, size: 64)
            VStack(alignment: .leading, spacing: 5) {
                Text(e.name).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text([e.version.isEmpty ? nil : e.version, e.bid].compactMap { $0 }.joined(separator: " • "))
                    .font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                RowPill(text: "Signed " + shortAgo(e.date) + (e.size > 0 ? " · " + ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file) : ""))
            }
            Spacer(minLength: 0)
            Menu {
                if let url = URL(string: e.link) {
                    Section("Install with") {
                        ForEach(Sideloaders.all, id: \.0) { s in
                            Button(s.0) { if let l = URL(string: s.1(e.link)) { UIApplication.shared.open(l) } }
                        }
                    }
                    ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") }
                }
                Button { UIPasteboard.general.string = e.link } label: { Label("Copy link", systemImage: "link") }
                Button(role: .destructive) { withAnimation { signed.remove(e) } } label: { Label("Remove from list", systemImage: "trash") }
            } label: {
                Image(systemName: "arrow.up.right").font(.system(size: 18, weight: .bold)).foregroundStyle(Color.dtAccent).frame(width: 40, height: 40)
            }
        }
        .padding(.vertical, 12)
    }
}
