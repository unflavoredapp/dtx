import SwiftUI

/// Installs an IPA signed on this phone straight to this device. If native install isn't set up yet it opens
/// the setup screen first instead of failing.
struct InstallSignedButton: View {
    let build: SignedBuild
    @ObservedObject private var installer = NativeInstaller.shared
    @State private var showSetup = false
    @State private var error: String?

    private var working: Bool { installer.isActive && installer.job?.bundleID == build.bundleID }

    var body: some View {
        if build.certName == BatchInjector.unsignedTag {
            Text("Unsigned").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        } else {
            installButton
        }
    }

    private var installButton: some View {
        Button { start() } label: {
            if working { ProgressView() }
            else { Text("Install").font(.caption.weight(.bold)).padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Color.dtAccent.opacity(0.18))).foregroundStyle(Color.dtAccent) }
        }
        .buttonStyle(.plain)
        .disabled(installer.isActive)
        .sheet(isPresented: $showSetup) { DeviceSetupView() }
        .alert("Couldn't install", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func start() {
        guard NativeInstaller.isSelected else { showSetup = true; return }
        Task {
            do {
                try await NativeInstaller.shared.install(build)
                ActivityStore.shared.log("Install", "installed `" + build.name + "` on this device")
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}
