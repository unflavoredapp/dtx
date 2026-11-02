import SwiftUI

/// The Tools tab: tools on this device, tools downloaded from your server as recipes, and tools that run on your server.
/// Tools with "Auto" on run by themselves in the background when the app opens; tap any tool to open its own view.
struct ToolsPanel: View {
    let url: String
    @StateObject private var runner = ToolRunner.shared
    @ObservedObject private var live = LiveSync.shared
    @State private var recipes: [Tool] = []
    @State private var server: [Tool] = []
    @State private var status: ServerTools.Status?
    @State private var opened: Tool?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if url.isEmpty {
                Text("Tools open the repo's IPA. This app has no repo IPA.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).card()
            } else {
                group("ON THIS DEVICE", "iphone") {
                    ForEach(ToolPrefs.arrange(ToolRegistry.bundled)) { row($0) }
                }
                if !recipes.isEmpty, live.flag("recipes") {
                    group("DOWNLOADED FROM YOUR SERVER", "arrow.down.circle") {
                        ForEach(ToolPrefs.arrange(recipes)) { row($0) }
                    }
                }
                if live.flag("serverTools") { group("RUNS ON YOUR SERVER", "server.rack") {
                    switch status {
                    case .none:
                        ProgressView().frame(maxWidth: .infinity).padding(12)
                    case .some(.unavailable(let why)):
                        Text(why).font(.footnote).foregroundStyle(.secondary)
                        Button("Try again") { Task { await load() } }.font(.footnote.weight(.semibold)).foregroundStyle(Color.dtAccent)
                    case .some(.ok(let n)):
                        if n == 0 { Text("Connected, but no tools are installed on the server yet.").font(.footnote).foregroundStyle(.secondary) }
                        ForEach(ToolPrefs.arrange(server)) { row($0) }
                    }
                } }
            }
        }
        .task(id: url) { await load() }
        .sheet(item: $opened) { t in ToolDetailView(tool: t, url: url) }
    }

    private func row(_ t: Tool) -> some View {
        ToolRow(tool: t, url: url, open: { opened = t })
    }

    private func group<C: View>(_ title: String, _ icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.caption.weight(.bold)).tracking(2).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func load() async {
        guard !url.isEmpty else { return }
        autoRun(ToolPrefs.arrange(ToolRegistry.bundled))
        status = nil
        async let r = RecipeStore.load()
        let (tools, st) = await ServerTools.load()
        server = tools; status = st
        recipes = await r
        autoRun(ToolPrefs.arrange(recipes) + ToolPrefs.arrange(server))
    }

    /// Starts every tool the person left on Auto, once per link.
    private func autoRun(_ tools: [Tool]) {
        for t in tools where ToolPrefs.runsByItself(t) {
            let s = runner.state(t, url)
            if !s.running && !s.done { runner.start(t, url: url) }
        }
    }
}

/// One line per tool: icon, name, a status, the Auto switch, and a tap to open its view.
struct ToolRow: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var runner = ToolRunner.shared
    let tool: Tool
    let url: String
    let open: () -> Void
    @State private var auto = false

    private var s: ToolRunner.State { runner.state(tool, url) }

    private var status: (String, Color) {
        if s.running { return (s.message.isEmpty ? "Working…" : s.message, .secondary) }
        if s.failed { return (s.message, .red) }
        if s.done { return (s.sections.isEmpty ? "Nothing to report" : "Done · \(s.sections.count) section\(s.sections.count == 1 ? "" : "s")", Color.dtAccent) }
        return (tool.summary, .secondary)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.dtAccent.opacity(0.14)).frame(width: 38, height: 38)
                        if s.running { ProgressView().scaleEffect(0.8) }
                        else { Image(systemName: tool.icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.dtAccent) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name).font(.subheadline.bold()).foregroundStyle(.white)
                        Text(status.0).font(.caption).foregroundStyle(status.1).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            VStack(spacing: 2) {
                AutoRunToggle(tool: tool, label: "", isOn: $auto, compact: true)
                    .onChange(of: auto) { on in
                        ToolPrefs.setAuto(tool, on)
                        if on, !ToolPrefs.autoPaused, tool.origin != .server || session.signedIn, !s.running, !s.done { runner.start(tool, url: url) }
                    }
                Text("AUTO").font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .onAppear { auto = ToolPrefs.auto(tool) }
    }
}

/// A tool's own view: what it does, its options, Run, and the full answer.
struct ToolDetailView: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var runner = ToolRunner.shared
    @Environment(\.dismiss) private var dismiss
    let tool: Tool
    let url: String
    @State private var values: [String: String] = [:]
    @State private var flags: [String: Bool] = [:]
    @State private var auto = false

    private var s: ToolRunner.State { runner.state(tool, url) }
    private var canRun: Bool { tool.origin != .server || session.signedIn }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: tool.icon).font(.system(size: 26, weight: .semibold)).foregroundStyle(Color.dtAccent)
                            .frame(width: 56, height: 56).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.dtAccent.opacity(0.14)))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(origin).font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(.secondary)
                            Text(tool.summary).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        AutoRunToggle(tool: tool, label: "Run automatically when I open an app", isOn: $auto)
                            .font(.subheadline).onChange(of: auto) { ToolPrefs.setAuto(tool, $0) }
                        ForEach(tool.options) { o in
                            if o.type == "bool" {
                                Toggle(o.label, isOn: Binding(get: { flags[o.key] ?? ((ToolPrefs.option(tool, o.key) ?? o.def) == "true") }, set: { flags[o.key] = $0 })).font(.subheadline).tint(.dtAccent)
                            } else {
                                TextField(o.label, text: Binding(get: { values[o.key] ?? ToolPrefs.option(tool, o.key) ?? o.def }, set: { values[o.key] = $0 }))
                                    .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .keyboardType(o.type == "number" ? .numberPad : .default)
                            }
                        }
                        Button { s.running ? runner.stop(tool, url) : run() } label: {
                            Label(s.running ? "Stop" : (s.done ? "Run again" : "Run"), systemImage: s.running ? "stop.fill" : "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(.dtAccent).disabled(!canRun)
                    }
                    .card()
                    if s.running { HStack { ProgressView(); Text(s.message).font(.footnote).foregroundStyle(.secondary) } }
                    else if !s.message.isEmpty { Text(s.message).font(.footnote).foregroundStyle(s.failed ? Color.red : Color.secondary) }
                    ForEach(s.sections) { SectionView(section: $0) }
                }
                .padding(16).padding(.bottom, 30)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(tool.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .onAppear { auto = ToolPrefs.auto(tool) }
    }

    private var origin: String {
        switch tool.origin { case .bundled: return "RUNS ON THIS DEVICE"; case .recipe: return "DOWNLOADED RECIPE · RUNS ON THIS DEVICE"; case .server: return "RUNS ON YOUR SERVER" }
    }

    private func run() {
        var opts: [String: String] = [:]
        for o in tool.options { opts[o.key] = o.type == "bool" ? ((flags[o.key] ?? ((ToolPrefs.option(tool, o.key) ?? o.def) == "true")) ? "true" : "false") : (values[o.key] ?? ToolPrefs.option(tool, o.key) ?? o.def) }
        runner.start(tool, url: url, options: opts)
    }
}


/// The "run automatically" switch. For a tool that runs on your server, the first time it is switched on the person has to say yes to it.
struct AutoRunToggle: View {
    let tool: Tool
    let label: String
    @Binding var isOn: Bool
    var compact = false
    @State private var asking = false

    var body: some View {
        let binding = Binding<Bool>(get: { isOn }, set: { want in
            if want && ToolPrefs.needsAutoConsent(tool) { asking = true } else { isOn = want }
        })
        Group {
            if compact { Toggle("", isOn: binding).labelsHidden().tint(.dtAccent).scaleEffect(0.8) }
            else { Toggle(label, isOn: binding).tint(.dtAccent) }
        }
        .confirmationDialog("Let \(tool.name) start by itself?", isPresented: $asking, titleVisibility: .visible) {
            Button("Allow it to start by itself") { ToolPrefs.giveAutoConsent(tool); isOn = true }
        } message: { Text("It runs on the Decrypt.Team server each time you open an app, and counts against your tool limit. You can switch it off here at any time, or pause all auto-run in Settings > Plugins.") }
    }
}
