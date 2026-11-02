import SwiftUI

/// The + button and "Start Build": pick an app from your repos, then go straight to its build screen.
struct QuickBuildView: View {
    @EnvironmentObject var store: RepoStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @StateObject private var searcher = AppSearcher()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Which app do you want to build?", text: $query)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    .padding(.horizontal, 18).padding(.vertical, 15).glowCapsule(strong: true)
                    LazyVStack(spacing: 0) {
                        if searcher.shown.isEmpty {
                            if searcher.searching { ProgressView().padding(.vertical, 30) }
                            else { Text(query.trimmingCharacters(in: .whitespaces).count < 2 ? "Type an app name from your repos." : "No apps found in your repos.").foregroundStyle(.secondary).padding(.vertical, 30) }
                        }
                        ForEach(searcher.shown) { app in
                            NavigationLink(value: app) {
                                HStack(spacing: 12) {
                                    AppIconView(url: app.icon, name: app.name, size: 46)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.name).font(.headline).foregroundStyle(.white).lineLimit(1)
                                        Text([app.current.map { "v" + $0.version }, app.repoName].compactMap { $0 }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 10)
                            }
                            Divider().overlay(Color.dtLine)
                        }
                        if searcher.hasMore { ProgressView().padding(.vertical, 14).onAppear { searcher.loadMore() } }
                    }
                    .card()
                }
                .padding(16)
            }
            .background(AppBackground())
            .navigationTitle("Start a build").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: AppEntry.self) { AppDetailView(app: $0) }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
            .task { searcher.minChars = 2 }
            .onChange(of: query) { _ in searcher.update(query: query, apps: store.apps) }
        }
        .preferredColorScheme(.dark)
    }
}

/// The server's analysis tools, on any IPA link.
struct ToolsHubView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""

    private var valid: Bool { link.hasPrefix("https://") && link.count > 12 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("IPA LINK").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("https://example.com/app.ipa", text: $link)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).textFieldStyle(.roundedBorder)
                        Text("Paste a direct link to an IPA. The server reads it and runs the tool you pick.").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).card()
                    if valid { ToolsPanel(url: link.trimmingCharacters(in: .whitespaces)) }
                }
                .padding(16)
            }
            .background(AppBackground())
            .navigationTitle("Tools").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
