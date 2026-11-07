import SwiftUI
import UniformTypeIdentifiers

/// Install method, device connection and pairing: everything native install needs, in one place.
struct DeviceSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(NativeInstaller.methodKey) private var method = "ota"
    @ObservedObject private var manager = DeviceInstallationManager.shared
    @ObservedObject private var pairing = DevicePairingService.shared
    @ObservedObject private var installer = NativeInstaller.shared
    @AppStorage(VPNReconnectCoordinator.enabledKey) private var reconnectOn = false
    @AppStorage(BackgroundKeepAlive.enabledKey) private var keepAlive = true
    @State private var importing = false
    @State private var confirmReset = false
    @State private var message: String?

    private var busy: Bool { manager.isBusy || installer.isActive }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Install method", selection: $method) {
                        Text("OTA (itms-services)").tag("ota")
                        Text("Native · built-in VPN").tag("native")
                    }.disabled(busy)
                    Text(method == "native"
                         ? "Installs straight to this device over a local VPN and a device pairing. Needs a build signed with a profile that allows Network Extensions (packet-tunnel-provider)."
                         : "Hands the signed IPA to iOS with an itms-services link.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Connection") {
                    Picker("Pairing", selection: $manager.mode) {
                        ForEach(DeviceConnectionMode.allCases) { Text($0.title).tag($0) }
                    }.disabled(busy)
                    Text(manager.mode == .builtIn
                         ? "Built-in manages a local VPN inside Uncrypt. Creating a pairing on this phone needs iOS 27+, Developer Mode and Local Network access."
                         : "Manual uses an imported pairingFile.plist and your own local VPN.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if manager.mode == .manual {
                        Button { importing = true } label: { Label("Import pairingFile.plist", systemImage: "square.and.arrow.down") }
                    }
                }
                Section("Status") { status }
                Section {
                    Toggle("Keep installing in the background", isOn: $keepAlive).tint(Color.dtAccent)
                    Toggle("Reconnect VPN after install", isOn: $reconnectOn).tint(Color.dtAccent)
                    if manager.mode == .builtIn {
                        Button("Forget built-in pairing", role: .destructive) { confirmReset = true }.disabled(busy)
                    }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("Native install")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
            .filePicker(isPresented: $importing, types: [.data, .propertyList]) { urls in
                if let u = urls.first { importPairing(u) }
            }
            .confirmationDialog("Forget the built-in pairing?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Forget", role: .destructive) { Task { await manager.resetPairing() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("You'll pair again the next time you set up the connection.") }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var status: some View {
        if let notice = manager.setupNotice { Text(notice).font(.footnote).foregroundStyle(.orange) }
        switch manager.phase {
        case .pairing:
            if let pin = pairing.pin {
                LabeledContent("Pairing code") { Text(pin).font(.title3.monospacedDigit().weight(.bold)).foregroundStyle(Color.dtAccent) }
                Text("Enter this code in Settings › Privacy & Security › Developer Mode › Pair with Uncrypt.").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Open Settings › Privacy & Security › Developer Mode and choose Pair with Uncrypt…").font(.footnote).foregroundStyle(.secondary)
            }
            Button("Cancel setup", role: .destructive) { manager.cancelSetup() }
        case .connecting:
            HStack(spacing: 10) { ProgressView(); Text("Connecting to this device…") }
            Text("Allow the VPN configuration if iOS asks.").font(.footnote).foregroundStyle(.secondary)
            Button("Cancel setup", role: .destructive) { manager.cancelSetup() }
        case .failed(let m):
            Label(m, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.footnote)
            Button("Retry setup") { Task { await manager.setUp() } }.disabled(busy)
        case .ready:
            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .configured:
            Label("Setup complete. Uncrypt reconnects when you install.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .idle:
            Button { Task { await manager.setUp() } } label: { Label("Set up connection", systemImage: "bolt.horizontal.circle.fill") }.disabled(busy)
            Text("Uncrypt also connects by itself on the first native install.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func importPairing(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard (try? PropertyListSerialization.propertyList(from: data, format: nil)) is [String: Any] else {
                message = "That isn't a pairing file."; return
            }
            try data.write(to: URL(fileURLWithPath: DeviceInstallationManager.legacyPairingPath), options: .atomic)
            message = "Pairing file imported."
        } catch { message = error.localizedDescription }
    }
}
