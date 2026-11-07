import SwiftUI
import UniformTypeIdentifiers

/// Certificate: keep your signing files (.p12 certificate and .mobileprovision profile) on this device so they're
/// one tap away. Files are copied into the app's own storage; swipe a row to remove it.
struct CertificateView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var importing = false
    @State private var error: String?

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Certificates", isDirectory: true)
    }

    private static var allowedTypes: [UTType] {
        ["p12", "mobileprovision"].compactMap { UTType(filenameExtension: $0) } + [.data]
    }

    var body: some View {
        NavigationStack {
            List {
                if files.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.seal").font(.system(size: 40)).foregroundStyle(Color.dtAccent)
                        Text("No certificate yet").font(.title3.weight(.semibold))
                        Text("Import your .p12 certificate and .mobileprovision profile.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                }
                ForEach(files, id: \.self) { url in
                    HStack(spacing: 14) {
                        Image(systemName: url.pathExtension.lowercased() == "p12" ? "key.fill" : "doc.badge.gearshape.fill")
                            .foregroundStyle(Color.dtAccent).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Text(url.pathExtension.lowercased() == "p12" ? "Certificate" : "Provisioning profile")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx { try? FileManager.default.removeItem(at: files[i]) }
                    reload()
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("Certificate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button { importing = true } label: { Image(systemName: "plus") } }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: Self.allowedTypes, allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): add(urls)
                case .failure(let e): error = e.localizedDescription
                }
            }
            .onAppear(perform: reload)
        }
        .preferredColorScheme(.dark)
    }

    private func reload() {
        let list = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        files = list.filter { ["p12", "mobileprovision"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func add(_ urls: [URL]) {
        error = nil
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        for src in urls {
            guard ["p12", "mobileprovision"].contains(src.pathExtension.lowercased()) else {
                error = "Only .p12 and .mobileprovision files can be added."
                continue
            }
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }
            let dst = Self.folder.appendingPathComponent(src.lastPathComponent)
            try? fm.removeItem(at: dst)
            do {
                try fm.copyItem(at: src, to: dst)
                ActivityStore.shared.log("Certificate", "imported `" + src.lastPathComponent + "`")
            } catch { self.error = error.localizedDescription }
        }
        reload()
    }
}
