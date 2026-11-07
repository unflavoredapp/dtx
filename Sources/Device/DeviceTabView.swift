import SwiftUI

/// Library | Device switch shown under the top bar.
enum LibraryMode: String, CaseIterable, Identifiable {
    case library = "Library", device = "Device"
    var id: String { rawValue }
}

/// "On this device": every user-installed app, read over the native connection. App Store apps with no
/// decrypted copy are flagged DRM · Locked and can be sent to Decrypt.
struct DeviceTabView: View {
    @EnvironmentObject var store: RepoStore
    @ObservedObject private var library = DeviceLibrary.shared
    @ObservedObject private var manager = DeviceInstallationManager.shared
    @ObservedObject private var builds = SignedBuildStore.shared
    @State private var pending: DeviceApp?
    @State private var showSetup = false
    @State private var showInstalled = false

    private var native: Bool { NativeInstaller.isSelected }

    var body: some View {
        LazyVStack(spacing: 0) {
            if !native {
                notice(icon: "iphone.and.arrow.forward", title: "Native install is off",
                       text: "Turn it on to list the apps on this device and install signed IPAs straight to it.",
                       button: "Set up") { showSetup = true }
            } else if library.apps.isEmpty && library.loading {
                ProgressView().padding(.top, 40)
            } else if library.apps.isEmpty {
                if let e = library.error {
                    notice(icon: "exclamationmark.triangle", title: "Couldn't read this device", text: e, button: "Set up") { showSetup = true }
                } else {
                    notice(icon: "iphone", title: "No apps yet", text: "Pull down to read the apps installed on this device.", button: "Refresh") { library.refresh() }
                }
            }
            if let e = library.error, !library.apps.isEmpty {
                Text(e).font(.footnote).foregroundStyle(.orange).padding(.vertical, 8)
            }
            ForEach(library.apps) { app in
                row(app)
                Divider().overlay(Color.dtLine)
            }
            if native {
                Button { showInstalled = true } label: {
                    Label("Manage installed apps", systemImage: "trash.slash").foregroundStyle(Color.dtAccent)
                }.padding(.top, 18)
            }
        }
        .task { library.refreshIfStale() }
        .confirmationDialog(pending.map { "Uninstall \($0.name)?" } ?? "", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) { if let a = pending { Task { await library.uninstall(a) } }; pending = nil }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { Text("This removes the app and all of its data from this device.") }
        .sheet(isPresented: $showSetup) { DeviceSetupView() }
        .sheet(isPresented: $showInstalled) { NavigationStack { InstalledAppsScreen() } .preferredColorScheme(.dark) }
    }

    /// Shown under the top bar as "7 Apps".
    static func strip(_ count: Int) -> String? { count > 0 ? "\(count) App\(count == 1 ? "" : "s")" : nil }

    private func locked(_ app: DeviceApp) -> Bool {
        app.isAppStore && !builds.entries.contains { $0.bundleID == app.bundleID }
    }

    private func row(_ app: DeviceApp) -> some View {
        let isLocked = locked(app)
        return HStack(spacing: 14) {
            Group {
                if let png = library.icons[app.bundleID], let img = UIImage(data: png) {
                    Image(uiImage: img).resizable().scaledToFill()
                        .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 14.4, style: .continuous))
                } else { AppIconView(url: nil, name: app.name, size: 64) }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(app.name).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text([app.version, app.bundleID].filter { !$0.isEmpty }.joined(separator: " • "))
                    .font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    if isLocked {
                        Label("DRM · Locked", systemImage: "lock.fill").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.red).padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color.red.opacity(0.14)))
                    } else { RowPill(text: "Installed") }
                    if let s = app.sizeText { RowPill(text: s) }
                }
            }
            Spacer(minLength: 0)
            Menu {
                if isLocked {
                    Button { store.pendingDecryptQuery = app.name; store.showQuickBuild = true } label: { Label("Decrypt", systemImage: "lock.open") }
                }
                Button(role: .destructive) { pending = app } label: { Label("Uninstall", systemImage: "trash") }
            } label: {
                Image(systemName: isLocked ? "lock.open" : "ellipsis.circle").font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.dtAccent)
            }
        }
        .padding(.vertical, 12)
    }

    private func notice(icon: String, title: String, text: String, button: String, _ action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(Color.dtAccent)
            Text(title).font(.title3.weight(.semibold))
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(button, action: action).buttonStyle(AccentButtonStyle())
        }
        .frame(maxWidth: .infinity).padding(.top, 50).padding(.horizontal, 20)
    }
}
