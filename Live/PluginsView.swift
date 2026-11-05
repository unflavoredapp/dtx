import SwiftUI

/// Every tool the app knows about, in one place: the ones inside the app, the recipes downloaded from your server, and the server's own.
@MainActor
final class ToolCatalog: ObservableObject {
    static let shared = ToolCatalog()
    @Published private(set) var recipes: [Tool] = []
    @Published private(set) var server: [Tool] = []
    @Published private(set) var serverNote = ""
    @Published private(set) var loading = false

    var bundled: [Tool] { ToolRegistry.bundled }
    var all: [Tool] { bundled + recipes + server }

    func load() async {
        loading = true; defer { loading = false }
        async let r = RecipeStore.load()
        let (s, st) = await ServerTools.load()
        server = s
        if case .unavailable(let why) = st { serverNote = why } else { serverNote = "" }
        recipes = await r
    }
}

/// Settings > Plugins: a table of every plugin. Tap one to open its controller.
struct PluginsTableView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var catalog = ToolCatalog.shared
    @ObservedObject private var live = LiveSync.shared
    @ObservedObject private var runner = ToolRunner.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Pause all auto-run", isOn: Binding(get: { ToolPrefs.autoPaused }, set: { ToolPrefs.autoPaused = $0; catalog.objectWillChange.send() })).tint(.dtAccent)
                } footer: { Text("Stops every tool from starting by itself. You can still run them by hand.") }.listRowBackground(Color.white.opacity(0.06))
                section("In the app", "iphone", catalog.bundled)
                section("Recipes from your server", "arrow.down.circle", catalog.recipes, empty: catalog.loading ? "Loading…" : "No recipes on the server.")
                section("Run on your server", "server.rack", catalog.server, empty: catalog.loading ? "Loading…" : (catalog.serverNote.isEmpty ? "No server tools installed." : catalog.serverNote))
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(AppBackground())
            .navigationTitle("Plugins").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { await catalog.load() }
            .task { await catalog.load() }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func section(_ title: String, _ icon: String, _ tools: [Tool], empty: String = "") -> some View {
        Section {
            if tools.isEmpty { Text(empty).font(.footnote).foregroundStyle(.secondary) }
            ForEach(tools) { t in
                NavigationLink { PluginControllerView(tool: t) } label: { PluginRowView(tool: t) }
                    .listRowBackground(Color.white.opacity(0.06))
            }
        } header: {
            Label(title.uppercased(), systemImage: icon).font(.caption.weight(.bold)).tracking(1.5)
        }
    }
}

private struct PluginRowView: View {
    let tool: Tool
    @ObservedObject private var live = LiveSync.shared

    var body: some View {
        let on = ToolPrefs.enabled(tool), auto = ToolPrefs.auto(tool), mark = ToolPrefs.seenState(tool)
        HStack(spacing: 12) {
            Image(systemName: tool.icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(on ? Color.dtAccent : Color.secondary)
                .frame(width: 36, height: 36).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.dtAccent.opacity(on ? 0.14 : 0.05)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.name).font(.subheadline.bold()).foregroundStyle(on ? Color.white : Color.secondary)
                    if let mark { Text(mark).font(.system(size: 9, weight: .bold)).tracking(0.5).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.dtAccent)).foregroundStyle(.black) }
                }
                Text(tool.version.isEmpty ? tool.summary : "v\(tool.version) · \(tool.summary)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(on ? (auto ? "AUTO" : "ON") : "OFF").font(.system(size: 10, weight: .bold)).tracking(1)
                .foregroundStyle(on ? (auto ? Color.dtAccent : Color.white.opacity(0.8)) : Color.secondary)
        }
    }
}

/// One plugin's controller: its details, switches, options and latest answer.
struct PluginControllerView: View {
    let tool: Tool
    @ObservedObject private var runner = ToolRunner.shared
    @ObservedObject private var live = LiveSync.shared
    @State private var enabled = true
    @State private var auto = false
    @State private var changed = false

    private var layer: String {
        switch tool.origin { case .bundled: return "Layer 3 · built into the app"; case .recipe: return "Layer 2 · recipe (data from your server)"; case .server: return "Layer 2 · runs on your server" }
    }
    private var liveInfo: String? {
        switch tool.origin {
        case .recipe: return live.recipes.first { "recipe-" + $0.id == tool.id }?.rev.map { "content \($0)" }
        case .server: return live.plugins.first { "server-" + $0.id == tool.id }?.version.map { "server reports v\($0)" }
        case .bundled: return nil
        }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: tool.icon).font(.system(size: 26, weight: .semibold)).foregroundStyle(Color.dtAccent)
                        .frame(width: 54, height: 54).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.dtAccent.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tool.name).font(.title3.bold())
                        Text(tool.summary).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.listRowBackground(Color.clear)
            }
            Section("Control") {
                Toggle("Show in Tools", isOn: $enabled).tint(.dtAccent)
                    .onChange(of: enabled) { ToolPrefs.setEnabled(tool, $0); changed = true }
                AutoRunToggle(tool: tool, label: "Run automatically when I open an app", isOn: $auto).disabled(!enabled)
                    .onChange(of: auto) { ToolPrefs.setAuto(tool, $0); changed = true }
                if ToolPrefs.autoPaused { Text("Auto-run is paused for every tool.").font(.footnote).foregroundStyle(Color.dtYellow) }
                if ToolPrefs.hasOwnChoice(tool) || changed {
                    Button("Reset to the default") { ToolPrefs.reset(tool); enabled = ToolPrefs.enabled(tool); auto = ToolPrefs.auto(tool); changed = false }.foregroundStyle(Color.dtAccent)
                }
            }.listRowBackground(Color.white.opacity(0.06))
            Section("Details") {
                kv("ID", tool.id)
                kv("Where it lives", layer)
                kv("Version", tool.version.isEmpty ? "—" : tool.version)
                if let liveInfo { kv("From the manifest", liveInfo) }
                kv("Runs", tool.origin == .server ? "On the server (needs sign-in)" : "On this phone")
                kv("Default", tool.auto ? "Runs automatically" : "Runs when you tap Run")
                kv("Capabilities", tool.capabilities.isEmpty ? "None declared — matched by keyword" : tool.capabilities.joined(separator: ", "))
            }.listRowBackground(Color.white.opacity(0.06))
            if !tool.options.isEmpty {
                Section {
                    ForEach(tool.options) { o in optionEditor(o) }
                } header: { Text("Options (\(tool.options.count))") } footer: { Text("These are the values the tool starts with, including when it runs by itself.") }
                .listRowBackground(Color.white.opacity(0.06))
            }
            Section("Latest result") {
                if let l = runner.last(tool) {
                    kv("For", l.url.split(separator: "/").last.map(String.init) ?? l.url)
                    kv("Answer", l.state.failed ? "Failed: " + l.state.message : (l.state.sections.isEmpty ? "Nothing to report" : "\(l.state.sections.count) section\(l.state.sections.count == 1 ? "" : "s")"))
                    kv("When", l.state.at.formatted(date: .abbreviated, time: .shortened))
                } else { Text("It hasn't run since the app opened. Open an app and go to its Tools tab.").font(.footnote).foregroundStyle(.secondary) }
            }.listRowBackground(Color.white.opacity(0.06))
        }
        .scrollContentBackground(.hidden).background(AppBackground())
        .navigationTitle(tool.name).navigationBarTitleDisplayMode(.inline)
        .onAppear { enabled = ToolPrefs.enabled(tool); auto = ToolPrefs.auto(tool); ToolPrefs.markSeen(tool) }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(v).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.subheadline)
    }

    @ViewBuilder
    private func optionEditor(_ o: PluginOption) -> some View {
        if o.type == "bool" {
            Toggle(o.label, isOn: Binding(get: { (ToolPrefs.option(tool, o.key) ?? o.def) == "true" }, set: { ToolPrefs.setOption(tool, o.key, $0 ? "true" : "false"); changed = true })).tint(.dtAccent)
        } else {
            HStack {
                Text(o.label).foregroundStyle(.secondary).font(.subheadline)
                TextField(o.def.isEmpty ? "default" : o.def, text: Binding(get: { ToolPrefs.option(tool, o.key) ?? "" }, set: { ToolPrefs.setOption(tool, o.key, $0.isEmpty ? nil : $0); changed = true }))
                    .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(o.type == "number" ? .numberPad : .default)
            }
        }
    }
}
