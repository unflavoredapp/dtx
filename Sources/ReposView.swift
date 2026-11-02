import SwiftUI

struct ReposView: View {
    @EnvironmentObject var store: RepoStore
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Add a repo") {
                    TextField("https://example.com/repo.json", text: $text)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button {
                        Task { await add() }
                    } label: {
                        if busy { ProgressView() } else { Text("Add") }
                    }
                    .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                Section("Your repos") {
                    if store.repos.isEmpty { Text("No repos added.").foregroundStyle(.secondary) }
                    ForEach(store.repos) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name).font(.headline)
                            Text(r.url).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .onDelete { idx in idx.map { store.repos[$0] }.forEach { store.remove($0) } }
                }
            }
            .scrollContentBackground(.hidden).background(AppBackground())
            .withTopBar(.repos, title: "Repos")
        }
    }

    private func add() async {
        busy = true; error = nil
        do { try await store.add(text); text = "" } catch { self.error = error.localizedDescription }
        busy = false
    }
}
