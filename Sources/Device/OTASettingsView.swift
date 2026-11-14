import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// On-device OTA over tetherless.dev — decrypt.team's replacement for the
/// discontinued backloop.dev loopback-HTTPS service.
struct OTASettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var mode = ServerConfig.certMode
    @State private var host = ServerConfig.installHost
    @State private var domain = ServerConfig.certDomain
    @State private var note: String?
    @State private var error: String?
    @State private var working = false
    @State private var importCustom = false
    @State private var trusted = LocalCAManager.isRootTrusted()
    @State private var hasRoot = LocalCAManager.hasRoot
    @State private var hasLeaf = LocalCAManager.hasLeaf

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Installs signed IPAs with itms-services over https://\(ServerConfig.installHost). The public pack from tetherless.dev is installed automatically on every launch. Point `*.\(ServerConfig.certDomain)` at 127.0.0.1 (same idea as backloop.dev).")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Domain") {
                    TextField("Domain", text: $domain)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Install host", text: $host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button("Save domain") { saveDomain() }
                    if let loopHint {
                        Text(loopHint).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("Cert mode") {
                    Picker("Mode", selection: $mode) {
                        Text("tetherless.dev pack").tag("public")
                        Text("Local CA").tag("local")
                        Text("Own TLS cert").tag("custom")
                    }
                    .onChange(of: mode) { m in
                        ServerConfig.setCertMode(m)
                        reload()
                    }
                    Text(modeBlurb).font(.footnote).foregroundStyle(.secondary)
                }

                if mode == "local" {
                    Section("Local CA") {
                        LabeledContent("Root") { Text(hasRoot ? "Ready" : "Missing").foregroundStyle(hasRoot ? .green : .orange) }
                        LabeledContent("Leaf") {
                            Text(hasLeaf ? (LocalCAManager.meta?.host ?? "Issued") : "Missing")
                                .foregroundStyle(hasLeaf ? .green : .orange)
                        }
                        LabeledContent("Trusted") { Text(trusted ? "Yes" : "Not yet").foregroundStyle(trusted ? .green : .orange) }
                        Button(working ? "Working…" : (hasRoot ? "Re-issue leaf for host" : "Create root + leaf")) {
                            Task { await ensureLocal() }
                        }.disabled(working)
                        if hasRoot {
                            Button("Install trust profile") { installTrust() }
                            Button("Export certs to Files") { _ = OTAFiles.exportLocalCA(); note = "Exported to On My iPhone › Uncrypt › OTA Certs" }
                            Button("Delete root + leaf", role: .destructive) {
                                LocalCAManager.reset(); OTAFiles.clear(); reload()
                                note = "Local CA deleted."
                            }
                        }
                    }
                }

                if mode == "custom" {
                    Section("Own TLS cert") {
                        Button("Import .crt / .pem / .key") { importCustom = true }
                        if ZefvCert.hasCustom {
                            Text("Custom cert covers: \(ZefvCert.customSANs.joined(separator: ", ").nilIfEmpty ?? "unreadable SANs")")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("Clear custom cert", role: .destructive) { ZefvCert.clearCustom(); reload() }
                        } else {
                            Text("Import a fullchain and private key for \(ServerConfig.installHost).").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                if mode == "public" {
                    Section("tetherless.dev pack") {
                        Text("Fetches \(ServerConfig.certSourceURL) (Feather/backloop pack.json or cert.php JSON). Public wildcard keys get revoked — prefer Local CA unless you control issuance carefully.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(working ? "Pulling…" : "Pull latest pack") {
                            Task { await pullPack() }
                        }.disabled(working)
                        if let exp = ZefvCert.effectiveNotAfter {
                            let days = Calendar.current.dateComponents([.day], from: Date(), to: exp).day ?? 0
                            Text(days < 0 ? "Pack expired" : "Pack expires in \(days)d · SANs: \(ZefvCert.effectiveSANs.joined(separator: ", "))")
                                .font(.footnote).foregroundStyle(days < 0 ? .red : .secondary)
                        }
                    }
                }

                if let note { Section { Text(note).font(.footnote).foregroundStyle(.secondary) } }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("On-Device OTA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
            .fileImporter(isPresented: $importCustom, allowedContentTypes: [.data, .pemCertificate, .x509Certificate], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    do { try ZefvCert.importCustom(files: urls); note = "Custom cert imported."; error = nil; reload() }
                    catch { self.error = error.localizedDescription }
                case .failure(let e): error = e.localizedDescription
                }
            }
            .onAppear { reload() }
        }
        .preferredColorScheme(.dark)
    }

    private var modeBlurb: String {
        switch mode {
        case "custom": return "Use a PEM fullchain + key you control for \(ServerConfig.installHost)."
        case "local": return "Issues a leaf for \(ServerConfig.installHost) from a root that only this phone trusts."
        default: return "Auto-installed on launch from \(ServerConfig.certSourceURL) (Feather/backloop pack.json shape)."
        }
    }

    private var loopHint: String? {
        "DNS: A record for \(ServerConfig.installHost) (or *.\(ServerConfig.certDomain)) → 127.0.0.1"
    }

    private func saveDomain() {
        let d = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard d.contains(".") else { error = "Enter a domain like tetherless.dev"; return }
        if h.isEmpty { h = d == ServerConfig.defaultDomain ? ServerConfig.defaultInstallHost : "ota.\(d)" }
        ServerConfig.setCertDomain(d)
        ServerConfig.setInstallHost(h)
        domain = ServerConfig.certDomain
        host = ServerConfig.installHost
        note = "Saved \(host). Re-issue the local leaf if you're on Local CA."
        error = nil
    }

    private func reload() {
        mode = ServerConfig.certMode
        host = ServerConfig.installHost
        domain = ServerConfig.certDomain
        trusted = LocalCAManager.isRootTrusted()
        hasRoot = LocalCAManager.hasRoot
        hasLeaf = LocalCAManager.hasLeaf
    }

    private func ensureLocal() async {
        working = true; error = nil; note = nil
        defer { working = false; reload() }
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard h.contains(".") else { error = "Enter a host like \(ServerConfig.defaultInstallHost)"; return }
        do {
            ServerConfig.setInstallHost(h)
            ServerConfig.setCertMode("local")
            mode = "local"
            _ = try LocalCAManager.ensureRoot()
            _ = try LocalCAManager.issueLeaf(host: h, force: true)
            _ = OTAFiles.exportLocalCA()
            note = "Leaf issued for \(h). Install the trust profile, then enable it under Certificate Trust Settings."
        } catch { self.error = error.localizedDescription }
    }

    private func installTrust() {
        guard let url = LocalCAManager.writeMobileConfig() else { error = "No root CA to install."; return }
        // Files / Safari open .mobileconfig; share sheet is the reliable path on-device.
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController?
            .present(av, animated: true)
        note = "After installing the profile, enable Full Trust in Settings › General › About › Certificate Trust Settings."
    }

    private func pullPack() async {
        working = true; error = nil; note = nil
        defer { working = false; reload() }
        do {
            let meta = try await ZefvCert.fetch()
            let days = meta.notAfter.map { Calendar.current.dateComponents([.day], from: Date(), to: $0).day ?? 0 }
            note = days.map { $0 < 0 ? "Pack expired." : "Pack refreshed · \($0)d left." } ?? "Pack refreshed."
        } catch { self.error = error.localizedDescription }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension UTType {
    static var pemCertificate: UTType { UTType(filenameExtension: "pem") ?? .data }
    static var x509Certificate: UTType { UTType(filenameExtension: "crt") ?? .data }
}
