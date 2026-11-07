import SwiftUI

/// Signer: shows whether you have a certificate and provisioning profile ready, and the builds waiting to be signed.
/// Builds from the server are unsigned, so this is the checklist before you sign and install one.
struct SignerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: RepoStore
    @ObservedObject private var signed = SignedStore.shared
    @State private var certs: [URL] = []

    private var p12: [URL] { certs.filter { $0.pathExtension.lowercased() == "p12" } }
    private var profiles: [URL] { certs.filter { $0.pathExtension.lowercased() == "mobileprovision" } }

    var body: some View {
        NavigationStack {
            List {
                Section("Ready to sign?") {
                    status("Certificate (.p12)", ok: !p12.isEmpty, detail: p12.first?.lastPathComponent ?? "Add one in Certificate")
                    status("Provisioning profile", ok: !profiles.isEmpty, detail: profiles.first?.lastPathComponent ?? "Add one in Certificate")
                    status("A build to sign", ok: !signed.items.isEmpty, detail: signed.items.first?.name ?? "Decrypt & Inject an app first")
                }
                if !signed.items.isEmpty {
                    Section("Builds") {
                        ForEach(signed.items.prefix(10)) { e in
                            HStack {
                                Text(e.name).lineLimit(1)
                                Spacer()
                                Text(e.version).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section { Text("Builds are unsigned. Sign them with your own certificate to install.").font(.footnote).foregroundStyle(.secondary) }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("Signer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
            .onAppear {
                let list = (try? FileManager.default.contentsOfDirectory(at: CertificateView.folder, includingPropertiesForKeys: nil)) ?? []
                certs = list
            }
        }
        .preferredColorScheme(.dark)
    }

    private func status(_ title: String, ok: Bool, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? Color.dtAccent : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}
