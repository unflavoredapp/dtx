import SwiftUI

struct AppIconView: View {
    let url: URL?
    let name: String
    var size: CGFloat = 52

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill()
            default:
                ZStack {
                    Color.gray.opacity(0.25)
                    Text(String(name.trimmingCharacters(in: .punctuationCharacters).prefix(1)).uppercased())
                        .font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.orange)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    }
}

struct SearchView: View {
    @EnvironmentObject var store: RepoStore
    @State private var query = ""

    private var results: [AppEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.apps }
        return store.apps.filter {
            $0.name.lowercased().contains(q) || $0.bid.lowercased().contains(q) || $0.developer.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if store.onlyDefault {
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.repos.isEmpty ? "No repos added" : "Searching the Delvek repo").font(.headline)
                                Text(store.repos.isEmpty ? "Add a repo to search for apps." : "Add your own repo to find more apps.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Add a repo") { store.tab = .repos }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                if let m = store.message { Section { Text(m).foregroundStyle(.secondary) } }
                Section {
                    ForEach(results) { app in
                        NavigationLink(value: app) {
                            HStack(spacing: 12) {
                                AppIconView(url: app.icon, name: app.name)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name).font(.headline)
                                    Text([app.current.map { "v" + $0.version }, app.repoName].compactMap { $0 }.joined(separator: " · "))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } footer: {
                    if !store.loading && results.isEmpty { Text("No apps found in your repos.") }
                }
            }
            .overlay { if store.loading && store.apps.isEmpty { ProgressView() } }
            .navigationTitle("Decrypt.team")
            .navigationDestination(for: AppEntry.self) { AppDetailView(app: $0) }
            .searchable(text: $query, prompt: "Search apps in your repos")
            .refreshable { await store.refresh() }
        }
    }
}
