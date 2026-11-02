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

/// Library: every app from every source, 10 at a time as you scroll. Search is the magnifier in the top bar.
struct SearchView: View {
    @EnvironmentObject var store: RepoStore
    @StateObject private var searcher = AppSearcher()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.onlyDefault {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.repos.isEmpty ? "No sources added" : "Showing the Delvek repo").font(.headline)
                                Text("Add your own repo to find more apps.").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Add a repo") { store.tab = .repos }.buttonStyle(AccentButtonStyle())
                        }
                        .card().padding(.vertical, 8)
                    }
                    if let m = store.message { Text(m).foregroundStyle(.secondary).padding(.vertical, 8) }
                    ForEach(searcher.shown) { app in
                        NavigationLink(value: app) { AppRow(app: app) }.buttonStyle(.plain)
                        Divider().overlay(Color.dtLine)
                    }
                    // the next 10 load when this row scrolls into view
                    if searcher.hasMore { ProgressView().padding(.vertical, 14).onAppear { searcher.loadMore() } }
                    if store.loading && store.apps.isEmpty { ProgressView().padding(.top, 40) }
                    else if !store.loading && !searcher.searching && searcher.shown.isEmpty { Text("No apps yet.").foregroundStyle(.secondary).padding(.top, 40) }
                }
                .padding(.horizontal, 14).padding(.bottom, 24)
            }
            .background(AppBackground())
            .navigationDestination(for: AppEntry.self) { AppDetailView(app: $0) }
            .withTopBar(.search, title: "Library", strip: searcher.total > 0 ? "\(formatCount(Int64(searcher.total))) Apps" : nil)
            .refreshable { await store.refresh() }
            .task(id: store.apps.count) { searcher.update(query: "", apps: store.apps) }
        }
    }
}
