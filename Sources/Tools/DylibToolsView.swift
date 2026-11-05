import SwiftUI

/// Tools filtered to whatever's aimed at dylibs, frameworks or the binary itself — opened straight from a
/// reconstructed dylib's row, already scoped to the app it came from. No IPA link to paste: `url` is the
/// app's own IPA, carried on the ReconResult since the moment it was pulled out and reconstructed.
struct DylibToolsView: View {
    let url: String
    let dylibName: String

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var runner = ToolRunner.shared
    @State private var recipes: [Tool] = []
    @State private var server: [Tool] = []
    @State private var loaded = false
    @State private var opened: Tool?

    private var bundled: [Tool] { ToolPrefs.arrange(ToolRegistry.bundled).filter(isDylibTool) }
    private var recipesDylib: [Tool] { ToolPrefs.arrange(recipes).filter(isDylibTool) }
    private var serverDylib: [Tool] { ToolPrefs.arrange(server).filter(isDylibTool) }
    private var isEmpty: Bool { bundled.isEmpty && recipesDylib.isEmpty && serverDylib.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if url.isEmpty {
                        Text("No app link for this dylib, so there's nothing to run tools against.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).card()
                    } else if !loaded {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else if isEmpty {
                        Text("No tools aimed at dylibs yet. Publish a recipe with \"dylib\" in its name (or framework/binary/library) to see it here.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).card()
                    } else {
                        if !bundled.isEmpty { group("ON THIS DEVICE", "iphone") { ForEach(bundled) { row($0) } } }
                        if !recipesDylib.isEmpty { group("FROM YOUR SERVER", "arrow.down.circle") { ForEach(recipesDylib) { row($0) } } }
                        if !serverDylib.isEmpty { group("RUNS ON YOUR SERVER", "server.rack") { ForEach(serverDylib) { row($0) } } }
                    }
                }
                .padding(16)
            }
            .background(AppBackground())
            .navigationTitle(dylibName).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
            .task { await load() }
            .sheet(item: $opened) { t in ToolDetailView(tool: t, url: url) }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ t: Tool) -> some View { ToolRow(tool: t, url: url, open: { opened = t }) }

    private func group<C: View>(_ title: String, _ icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.caption.weight(.bold)).tracking(2).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func load() async {
        guard !url.isEmpty else { loaded = true; return }
        async let r = RecipeStore.load()
        let (s, _) = await ServerTools.load()
        recipes = await r
        server = s
        loaded = true
    }
}
