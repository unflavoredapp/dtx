import SwiftUI

struct AppDetailView: View {
    @EnvironmentObject var store: RepoStore
    @Environment(\.openURL) private var openURL
    let app: AppEntry

    private let sideloaders: [(String, (String) -> String)] = [
        ("Feather", { "feather://install/" + $0 }),
        ("E-Sign", { "esign://install?url=" + $0.urlEncoded }),
        ("GBox", { "gbox://install?url=" + $0.urlEncoded }),
        ("FlareStore", { "flarestore://install?url=" + $0.urlEncoded }),
        ("AltStore", { "altstore://install?url=" + $0.urlEncoded }),
    ]

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    AppIconView(url: app.icon, name: app.name, size: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.title3.bold())
                        Text(app.bid).font(.footnote).foregroundStyle(.secondary)
                        if !app.developer.isEmpty { Text(app.developer).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                Button {
                    store.openInStudio(app)
                } label: {
                    Label("Decrypt & Inject in Studio", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            Section("Versions in \(app.repoName)") {
                if app.versions.isEmpty { Text("This repo lists no downloads for this app.").foregroundStyle(.secondary) }
                ForEach(app.versions) { v in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("v" + v.version).font(.headline)
                            Spacer()
                            if v.size > 0 { Text(ByteCountFormatter.string(fromByteCount: v.size, countStyle: .file)).foregroundStyle(.secondary) }
                        }
                        if !v.minOS.isEmpty || !v.date.isEmpty {
                            Text([v.minOS.isEmpty ? nil : "iOS " + v.minOS + "+", v.date.isEmpty ? nil : String(v.date.prefix(10))]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let u = v.url {
                            HStack {
                                Button("Download IPA") { openURL(u) }.buttonStyle(.bordered)
                                Menu("Install with…") {
                                    ForEach(sideloaders, id: \.0) { s in
                                        Button(s.0) { if let l = URL(string: s.1(u.absoluteString)) { openURL(l) } }
                                    }
                                }.buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension String {
    var urlEncoded: String { addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self }
}
