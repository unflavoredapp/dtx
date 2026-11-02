import SwiftUI

/// Settings: grouped rows with a lime icon tile, a title and a line under it.
struct SettingsView: View {
    @EnvironmentObject var store: RepoStore
    @EnvironmentObject var session: Session
    @ObservedObject private var signed = SignedStore.shared
    @ObservedObject private var live = LiveSync.shared
    @State private var showUpdates = false
    @State private var showPlugins = false
    @State private var showAbout = false
    @State private var showChangelog = false
    @State private var confirmSignOut = false
    @State private var confirmClear = false

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    header("GENERAL")
                    row("info", "About", "App information and version") { showAbout = true }
                    row("doc.text.fill", "Changelog", "What changed in Decrypt.Team") { showChangelog = true }

                    header("PLUGINS & UPDATES")
                    row("arrow.triangle.2.circlepath", "Live Update", live.updateAvailable ? "Release \(live.manifest?.rev ?? 0) is available" : (live.rev == 0 ? "Runtime \(Runtime.version) · tap to sync" : "Runtime \(Runtime.version) · release #\(live.rev)")) { showUpdates = true }
                    row("puzzlepiece.extension.fill", "Plugins", "Every tool, its version and switches") { showPlugins = true }

                    header("ACCOUNT")
                    row("person.fill", "Account", "\(session.username ?? "") · \(session.staff ? "Staff" : "Closed beta")") { confirmSignOut = true }

                    header("SERVER")
                    HStack(spacing: 14) {
                        tile("server.rack")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Server").font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
                            TextField("https://decrypt.team", text: $store.server)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                .font(.system(size: 15)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 12)
                    Divider().overlay(Color.dtLine)

                    header("DATA")
                    row("arrow.clockwise", "Reload sources", "Fetch every repo again") { Task { await store.refresh() } }
                    row("trash.fill", "Clear signed list", "\(signed.items.count) build\(signed.items.count == 1 ? "" : "s") on this phone") { confirmClear = true }
                }
                .padding(.horizontal, 14).padding(.bottom, 24)
            }
            .background(AppBackground())
            .withTopBar(.settings, title: "Settings", actions: [.label("DECRYPT.TEAM " + version)])
            .sheet(isPresented: $showChangelog) { ChangelogView() }
            .sheet(isPresented: $showUpdates) { UpdateCenterView() }
            .sheet(isPresented: $showPlugins) { PluginsTableView() }
            .sheet(isPresented: $showAbout) { aboutSheet }
            .confirmationDialog("Sign out of \(session.username ?? "this account")?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await session.signOut() } }
            }
            .confirmationDialog("Remove every build from the Signed list?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear list", role: .destructive) { signed.clear() }
            } message: { Text("The builds stay on the server; only this list is cleared.") }
        }
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.system(size: 17, weight: .semibold)).tracking(3).foregroundStyle(.secondary).padding(.top, 22).padding(.bottom, 4).padding(.leading, 4)
    }

    private func tile(_ icon: String) -> some View {
        Image(systemName: icon).font(.system(size: 22, weight: .bold)).foregroundStyle(Color.dtAccent)
            .frame(width: 48, height: 48)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.dtAccent.opacity(0.14)))
    }

    private func row(_ icon: String, _ title: String, _ sub: String, _ action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 14) {
                    tile(icon)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
                        Text(sub).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right.square").font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.dtAccent)
                }
                .padding(.vertical, 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().overlay(Color.dtLine)
        }
    }

    private var aboutSheet: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image("Logo").resizable().frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)).padding(.top, 24)
                (Text("Decrypt.").foregroundColor(.white) + Text("Team").foregroundColor(.dtAccent)).font(.title.bold())
                Text("Version \(version)").foregroundStyle(.secondary)
                Text("A closed-beta companion for Decrypt.Team staff. Decrypting and building run on the Decrypt.Team server; this app only shows the screens. Builds are unsigned, so sign them with your own certificate to install.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
                Spacer()
            }
            .frame(maxWidth: .infinity).background(AppBackground())
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { showAbout = false } } }
        }
        .preferredColorScheme(.dark)
    }
}
