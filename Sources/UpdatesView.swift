import SwiftUI

/// Apps you signed or injected that your repos now list in a newer version.
struct UpdatesView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: RepoStore
    @ObservedObject private var builds = SignedBuildStore.shared

    struct Item: Identifiable { let build: SignedBuild; let app: AppEntry; let latest: String; var id: String { build.id } }
    @State private var items: [Item] = []

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    Text(builds.entries.isEmpty ? "Sign or inject an app first. Newer versions show up here." : "Everything you signed is up to date.")
                        .foregroundStyle(.secondary).font(.footnote)
                }
                ForEach(items) { it in
                    HStack(spacing: 12) {
                        AppIconView(url: it.app.icon, name: it.app.name, size: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(it.build.name).foregroundStyle(.white).lineLimit(1)
                            Text("v" + it.build.version + "  →  v" + it.latest).font(.caption.monospaced()).foregroundStyle(Color.dtAccent)
                        }
                        Spacer()
                        Button("Update") { open(it.app) }.buttonStyle(.bordered).tint(Color.dtAccent)
                    }
                }
            }
            .scrollContentBackground(.hidden).background(AppBackground())
            .navigationTitle("Updates").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
            .task(id: store.apps.count + builds.entries.count) { compute() }
        }
        .preferredColorScheme(.dark)
    }

    private func compute() {
        let wanted = Set(builds.entries.map(\.bundleID))
        var latest: [String: AppEntry] = [:]
        for a in store.apps where wanted.contains(a.bid) { if latest[a.bid] == nil { latest[a.bid] = a } }
        items = builds.entries.compactMap { b in
            guard let app = latest[b.bundleID], let cur = app.current, compareVersions(cur.version, b.version) > 0 else { return nil }
            return Item(build: b, app: app, latest: cur.version)
        }
    }

    /// Opens the app's page, where Sign IPA starts the new build.
    private func open(_ app: AppEntry) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { store.pickedApp = app }
    }
}
