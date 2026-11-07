import SwiftUI

/// Browse: the sources (repos) you added. Tap one to see its apps; Edit removes, + adds.
struct ReposView: View {
    @EnvironmentObject var store: RepoStore
    @State private var editing = false
    @State private var showAdd = false
    @State private var counts: [String: Int] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.repos.isEmpty {
                        Text("No sources yet. Tap + to add a repo.").foregroundStyle(.secondary).padding(.top, 40)
                    }
                    ForEach(store.repos) { r in
                        HStack(spacing: 10) {
                            if editing {
                                Button { withAnimation { store.remove(r) } } label: { Image(systemName: "minus.circle.fill").font(.title2).foregroundStyle(.red) }
                            }
                            NavigationLink(value: r) { row(r) }.buttonStyle(.plain)
                            ShareLink(item: r.url) {
                                Image(systemName: "arrow.up.right.square").font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(Color.dtAccent).padding(10)
                                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.dtAccent, lineWidth: 1.5).padding(7))
                            }
                        }
                        .padding(.vertical, 10)
                        Divider().overlay(Color.dtLine)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 24)
            }
            .background(AppBackground())
            .navigationDestination(for: RepoInfo.self) { SourceBrowseView(repo: $0) }
            .navigationDestination(for: AppEntry.self) { AppPageView(app: $0) }
            .withTopBar(.repos, title: "Sources", actions: [.search, .text(editing ? "Done" : "Edit", { withAnimation { editing.toggle() } }), .icon("plus", { showAdd = true })])
            .sheet(isPresented: $showAdd) { AddRepoView() }
            .task(id: store.apps.count) { counts = Dictionary(grouping: store.apps, by: { $0.repoURL }).mapValues { $0.count } }
        }
    }

    private func row(_ r: RepoInfo) -> some View {
        HStack(spacing: 14) {
            Text(String(r.name.prefix(1)).uppercased())
                .font(.system(size: 30, weight: .bold)).foregroundStyle(Color.dtAccent)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.dtAccent.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.dtAccent.opacity(0.25)))
            VStack(alignment: .leading, spacing: 3) {
                Text(r.name).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(URL(string: r.url)?.host ?? r.url).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1)
                Text(counts[r.url].map { "\(formatCount(Int64($0))) apps" } ?? (store.loading ? "loading…" : "– apps"))
                    .font(.system(size: 15, design: .monospaced)).foregroundStyle(Color.dtAccent)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// Adds a repo by its link.
struct AddRepoView: View {
    @EnvironmentObject var store: RepoStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/repo.json", text: $text)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                } header: { Text("Repo link") } footer: {
                    Text("Paste a repo link. AltStore, SideStore and custom repos work.")
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
                Section {
                    Button { Task { await add() } } label: { if busy { ProgressView() } else { Text("Add source") } }
                        .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .scrollContentBackground(.hidden).background(AppBackground())
            .navigationTitle("Add a source").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private func add() async {
        busy = true; error = nil
        do { try await store.add(text); dismiss() } catch { self.error = error.localizedDescription }
        busy = false
    }
}
