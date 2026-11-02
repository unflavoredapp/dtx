import SwiftUI

/// The Live Update Center: what version the app is running, what the server offers, and the controls for syncing, rolling back and trying early features.
struct UpdateCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var live = LiveSync.shared
    @ObservedObject private var catalog = ToolCatalog.shared
    @State private var confirmRollback: LiveRelease?
    @State private var showPlugins = false

    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f }()

    var body: some View {
        NavigationStack {
            List {
                runtimeSection
                switch live.keyState { case .changed(let k): keyAlert(k, first: false); case .unenrolled(let k): keyAlert(k, first: true); default: EmptyView() }
                layersSection
                if let exps = live.config.experimental, !exps.isEmpty { experimentsSection(exps) }
                historySection
                securitySection
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(AppBackground())
            .navigationTitle("Live Update").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { await live.sync() }
            .task { await live.syncIfDue(); await catalog.load() }
            .sheet(isPresented: $showPlugins) { PluginsTableView() }
            .confirmationDialog("Go back to release \(confirmRollback?.rev ?? 0)?", isPresented: Binding(get: { confirmRollback != nil }, set: { if !$0 { confirmRollback = nil } }), titleVisibility: .visible) {
                if let r = confirmRollback { Button("Roll back to \(r.rev)", role: .destructive) { Task { await live.rollback(to: r.rev) } } }
            } message: { Text("The app stays on that release and stops upgrading by itself until you tap Resume updates.") }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: sections

    private var runtimeSection: some View {
        Section {
            kv("Runtime", "\(Runtime.version) · build \(Runtime.build)")
            kv("Live release", live.rev == 0 ? "None (built-in settings)" : "#\(live.rev)" + ((live.applied?.note ?? "").isEmpty ? "" : " · \(live.applied!.note)"))
            kv("Last sync", live.lastSync.map { Self.stamp.string(from: $0) } ?? "Never")
            Picker("Channel", selection: $live.channel) {
                Text("Stable").tag("stable"); Text("Beta").tag("beta"); Text("Experimental").tag("experimental")
            }.pickerStyle(.segmented).listRowSeparator(.hidden)
            Toggle("Sync automatically", isOn: $live.autoSync).tint(.dtAccent)
            if let h = live.holdRev {
                Label("Held at release \(h). It won't upgrade by itself.", systemImage: "pause.circle.fill").font(.footnote).foregroundStyle(Color.dtYellow)
                Button("Resume updates") { Task { await live.resume() } }.foregroundStyle(Color.dtAccent)
            } else if live.updateAvailable {
                Label("Release \(live.manifest?.rev ?? 0) is available.", systemImage: "arrow.down.circle.fill").font(.footnote).foregroundStyle(Color.dtAccent)
            }
            if live.needsNative { Label("A release is waiting for a newer app build.", systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Color.dtYellow) }
            if !live.lastError.isEmpty { Text(live.lastError).font(.footnote).foregroundStyle(.red) }
            Button { Task { await live.sync() } } label: {
                HStack { if live.syncing { ProgressView() }; Text(live.syncing ? "Syncing…" : "Sync now") }.frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).tint(.dtAccent).foregroundStyle(.black).disabled(live.syncing)
        } header: { Text("RUNTIME") }
        .listRowBackground(Color.white.opacity(0.06))
    }

    private func keyAlert(_ key: String, first: Bool) -> some View {
        Section {
            Label(first ? "Confirm the server's signing key" : "The server is signing with a different key", systemImage: "key.fill").foregroundStyle(Color.dtYellow).font(.subheadline.bold())
            Text("Server key:  \(live.fingerprint(ofNew: key))" + (first ? "" : "\nTrusted now:  \(live.pinnedKeyFingerprint ?? "none")")).font(.system(.footnote, design: .monospaced))
            Text(first ? "Compare this with the fingerprint printed by `node live-admin.js status` on your server. Only trust it if they match exactly. Nothing is applied until you do." : "Only trust it if you changed the server's key yourself.").font(.footnote).foregroundStyle(.secondary)
            Button(first ? "They match: trust this key" : "Trust the new key") { live.trustPendingKey() }.foregroundStyle(Color.dtAccent)
        }.listRowBackground(Color.white.opacity(0.06))
    }

    private var layersSection: some View {
        Section {
            let cfg = live.config, flags = cfg.flags?.count ?? 0
            layer("slider.horizontal.3", "1 · Live configuration", live.rev == 0 ? "Using the app's built-in settings" : "Release #\(live.rev): \(flags) flag\(flags == 1 ? "" : "s"), \((cfg.hide ?? []).count) tool\((cfg.hide ?? []).count == 1 ? "" : "s") hidden" + (cfg.theme?.accent != nil ? ", custom accent" : ""))
            Button { showPlugins = true } label: {
                HStack { layer("puzzlepiece.extension.fill", "2 · Plugins", "\(catalog.bundled.count) in the app · \(catalog.recipes.count) recipes · \(catalog.server.count) on the server"); Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            }.buttonStyle(.plain)
            let drift = live.reconcile(server: catalog.server, recipes: catalog.recipes)
            if !drift.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Out of step (\(drift.count))", systemImage: "exclamationmark.triangle.fill").font(.footnote.bold()).foregroundStyle(Color.dtYellow)
                    ForEach(drift, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
            layer("app.badge.fill", "3 · Native app", nativeLine)
            if live.nativeNewer, let s = live.native?.url, let u = URL(string: s), u.scheme == "https" { Link("Get build \(live.native?.build ?? 0)", destination: u).foregroundStyle(Color.dtAccent) }
            if let notes = live.native?.notes, live.nativeNewer, !notes.isEmpty { Text(notes).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("LAYERS") }
        .listRowBackground(Color.white.opacity(0.06))
    }
    private var nativeLine: String {
        guard let n = live.native?.build else { return "Build \(Runtime.build). No new IPA announced." }
        return n > Runtime.build ? "Build \(Runtime.build) installed · build \(n) is out" : "Build \(Runtime.build). Up to date."
    }

    private func experimentsSection(_ list: [LiveExperiment]) -> some View {
        Section {
            ForEach(list) { e in
                Toggle(isOn: Binding(get: { live.experimentOn(e.id) }, set: { live.setExperiment(e.id, $0) })) {
                    VStack(alignment: .leading, spacing: 2) { Text(e.title); if let d = e.detail, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) } }
                }.tint(.dtAccent)
            }
        } header: { Text("EXPERIMENTAL") } footer: { Text("Early features. They can change or disappear between releases.") }
        .listRowBackground(Color.white.opacity(0.06))
    }

    private var historySection: some View {
        Section {
            if let releases = live.manifest?.history, !releases.isEmpty {
                ForEach(releases) { r in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("#\(r.rev)" + ((r.channel ?? "stable") == "stable" ? "" : " · \(r.channel ?? "")") + (r.rev == live.rev ? " · current" : "")).font(.subheadline.bold())
                            if let n = r.note, !n.isEmpty { Text(n).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if r.rev != live.rev { Button(r.rev < live.rev ? "Roll back" : "Apply") { if r.rev < live.rev { confirmRollback = r } else { Task { await live.rollback(to: r.rev) } } }
                            .font(.footnote.weight(.semibold)).foregroundStyle(Color.dtAccent).buttonStyle(.borderless) }
                    }
                }
            }
            if live.log.isEmpty { Text("Nothing has been applied yet.").font(.footnote).foregroundStyle(.secondary) }
            ForEach(live.log.prefix(12)) { e in
                HStack(alignment: .top) {
                    Text(e.event.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(e.event == "rejected" || e.event == "held" ? Color.dtYellow : Color.dtAccent).frame(width: 78, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) { Text(e.note).font(.footnote); Text(Self.stamp.string(from: e.at)).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        } header: { Text("UPDATE HISTORY") }
        .listRowBackground(Color.white.opacity(0.06))
    }

    private var securitySection: some View {
        Section {
            kv("Signing key", live.pinnedKeyFingerprint ?? "Not seen yet")
            kv("Trust", { switch live.keyState { case .pinnedByApp: return "Built into this app"; case .trusted: return "Confirmed by you"; case .unenrolled: return "Waiting for you to confirm"; case .changed: return "Changed: needs your OK"; case .none: return "Not checked yet" } }())
        } header: { Text("SECURITY") } footer: { Text("Updates only apply when their signature matches this key. Nothing downloaded is run as code.") }
        .listRowBackground(Color.white.opacity(0.06))
    }

    private func layer(_ icon: String, _ title: String, _ sub: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.dtAccent).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.subheadline.bold()); Text(sub).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
        }
    }
    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) { Text(k).foregroundStyle(.secondary); Spacer(minLength: 12); Text(v).multilineTextAlignment(.trailing) }.font(.subheadline)
    }
}

/// An announcement from the latest live release, shown at the top of Home until it is dismissed.
struct LiveBannerView: View {
    @ObservedObject private var live = LiveSync.shared
    @State private var dismissed: String = UserDefaults.standard.string(forKey: "dt.live.banner") ?? ""

    var body: some View {
        if let b = live.config.banner, b.id != dismissed {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles").foregroundStyle(Color.dtAccent).font(.system(size: 18, weight: .semibold))
                VStack(alignment: .leading, spacing: 3) {
                    Text(b.title).font(.subheadline.bold()).foregroundStyle(.white)
                    Text(b.text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let s = b.url, let u = URL(string: s), u.scheme == "https" { Link("Learn more", destination: u).font(.footnote.weight(.semibold)).foregroundStyle(Color.dtAccent) }
                }
                Spacer(minLength: 4)
                Button { dismissed = b.id; UserDefaults.standard.set(b.id, forKey: "dt.live.banner") } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).card()
        }
    }
}
