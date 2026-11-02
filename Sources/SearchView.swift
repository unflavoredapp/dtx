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
                        .font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(Color.dtAccent)
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

    @StateObject private var searcher = AppSearcher()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search apps in your repos…", text: $query)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 13).glowCapsule(strong: true)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                if store.onlyDefault {
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.repos.isEmpty ? "No repos added" : "Searching the Delvek repo").font(.headline)
                                Text(store.repos.isEmpty ? "Add a repo to search for apps." : "Add your own repo to find more apps.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Add a repo") { store.tab = .repos }.buttonStyle(AccentButtonStyle())
                        }
                    }
                }
                if let m = store.message { Section { Text(m).foregroundStyle(.secondary) } }
                Section {
                    ForEach(searcher.shown) { app in
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
                    if searcher.hasMore {
                        // the next 10 load when this row scrolls into view
                        HStack { Spacer(); ProgressView(); Spacer() }.onAppear { searcher.loadMore() }
                    }
                } footer: {
                    if !store.loading && !searcher.searching && searcher.shown.isEmpty { Text("No apps found in your repos.") }
                    else if searcher.total > 0 { Text("Showing \(searcher.shown.count) of \(formatCount(Int64(searcher.total)))") }
                }
            }
            .overlay { if store.loading && store.apps.isEmpty { ProgressView() } }
            .scrollContentBackground(.hidden).background(AppBackground())
            .navigationDestination(for: AppEntry.self) { AppDetailView(app: $0) }
            .withTopBar(.search, title: "Apps")
            .refreshable { await store.refresh() }
            .task { searcher.update(query: query, apps: store.apps) }
            .onChange(of: query) { _ in searcher.update(query: query, apps: store.apps) }
            .onChange(of: store.loading) { _ in searcher.update(query: query, apps: store.apps) }
        }
    }
}
