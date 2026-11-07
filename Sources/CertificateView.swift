import SwiftUI
import UniformTypeIdentifiers

/// Certificate: import a .p12 + .mobileprovision (loose files, or one .zip with an optional password .txt),
/// see who they belong to and when they expire, and pick the one Signer uses.
struct CertificateView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = CertificateStore.shared
    @State private var importing = false
    @State private var pending: CertImportBundle?
    @State private var askPassword = false
    @State private var password = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                if store.certificates.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.seal").font(.system(size: 40)).foregroundStyle(Color.dtAccent)
                        Text("No certificate yet").font(.title3.weight(.semibold))
                        Text("Import a .p12 and its .mobileprovision, or one .zip that holds both.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                }
                ForEach(store.certificates) { cert in
                    row(cert)
                }
                .onDelete { idx in
                    let list = store.certificates
                    for i in idx { store.delete(list[i]); ActivityStore.shared.log("Certificate", "removed `" + list[i].name + "`") }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("Certificate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button { importing = true } label: { Image(systemName: "plus") } }
            }
            .filePicker(isPresented: $importing, types: [.data, .zip], multiple: true) { urls in read(urls) }
            .alert("Certificate password", isPresented: $askPassword) {
                SecureField("Password", text: $password)
                Button("Import") { finishImport(password: password) }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: { Text("The password of the .p12 file. Leave it empty if it has none.") }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ cert: Certificate) -> some View {
        let info = store.cachedProfileInfo(for: cert)
        let active = store.activeID == cert.id
        return Button { store.activeID = cert.id } label: {
            HStack(spacing: 14) {
                Image(systemName: active ? "checkmark.seal.fill" : "seal")
                    .font(.system(size: 24)).foregroundStyle(active ? Color.dtAccent : Color.secondary).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(cert.name).font(.headline).foregroundStyle(.white).lineLimit(1)
                    if let team = info.team { Text(team).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                    Text(expiryText(info)).font(.caption).foregroundStyle(info.isExpired ? Color.red : (info.isExpiringSoon ? Color.orange : Color.secondary))
                }
                Spacer()
                if active { Text("Active").font(.caption.weight(.bold)).foregroundStyle(Color.dtAccent) }
            }
        }
        .buttonStyle(.plain)
    }

    private func expiryText(_ info: ProfileInfo) -> String {
        guard let days = info.daysUntilExpiry else { return "Expiry unknown" }
        if info.isExpired { return "Expired" }
        return days == 0 ? "Expires today" : "Expires in \(days) day\(days == 1 ? "" : "s")"
    }

    // MARK: importing

    private func read(_ urls: [URL]) {
        message = nil
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        let bundle = CertImportBundle.read(urls)
        if !bundle.problems.isEmpty { message = bundle.problems.joined(separator: " "); return }
        guard bundle.p12 != nil else { message = "Add the .p12 certificate too."; return }
        guard bundle.profile != nil else { message = "Add the .mobileprovision profile too."; return }
        pending = bundle
        if let pw = bundle.password { finishImport(password: pw) } else { password = ""; askPassword = true }
    }

    private func finishImport(password: String) {
        guard let b = pending, let p12 = b.p12, let profile = b.profile else { return }
        pending = nil
        let name = (p12.name as NSString).deletingPathExtension
        do {
            let cert = try store.importPair(name: name, p12: p12.data, password: password, provision: profile.data)
            ActivityStore.shared.log("Certificate", "imported `" + cert.name + "`")
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}
