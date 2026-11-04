import SwiftUI
import UIKit

/// Browse → edit → rebuild for a reconstructed dylib's recovered Objective-C project. Presented imperatively
/// (see ReconEditorPresenter) so it works reliably on top of the Ai-Decrypt chat sheet.
struct ReconEditorView: View {
    let jobID: String
    let dylibName: String
    @Environment(\.dismiss) private var dismiss

    @State private var files: [ReconstructAPI.DecompFile] = []
    @State private var loading = true
    @State private var error: String?
    @State private var building = false
    @State private var buildLine = ""

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Loading source…")
                } else if let error {
                    VStack(spacing: 10) {
                        Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                        Button("Retry") { Task { await load() } }
                    }.padding()
                } else {
                    List {
                        if building {
                            Section {
                                HStack(spacing: 8) { ProgressView().scaleEffect(0.8); Text(buildLine.isEmpty ? "Building dylib…" : buildLine).font(.caption).lineLimit(2) }
                            }
                        }
                        ForEach(files) { f in
                            NavigationLink(value: f.path) {
                                HStack {
                                    Image(systemName: icon(for: f.path)).font(.caption).foregroundStyle(Color.dtAccent)
                                    Text(f.path).font(.system(size: 13, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(bytes(f.size)).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(dylibName)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { path in
                ReconFileEditor(jobID: jobID, path: path)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { rebuild() } label: {
                        if building { ProgressView() } else { Label("Build dylib", systemImage: "hammer.fill") }
                    }.disabled(building || loading)
                }
            }
            .task { await load() }
            .preferredColorScheme(.dark)
            .tint(.dtAccent)
        }
    }

    private func load() async {
        loading = true; error = nil
        do { files = try await ReconstructAPI.files(jobID: jobID) }
        catch { self.error = "Couldn't load the recovered project: \(error.localizedDescription)" }
        loading = false
    }

    private func rebuild() {
        building = true; buildLine = ""
        Task {
            do {
                let name = try await ReconstructAPI.build(jobID: jobID) { line in buildLine = line }
                building = false
                // offer the freshly built dylib
                if let url = try? await FileDownloader().download(path: ReconstructAPI.dylibDownloadPath(jobID: jobID), name: name) { _ in } {
                    SharePresenter.present(url)
                }
            } catch {
                building = false
                self.error = "Build failed: \(error.localizedDescription)"
            }
        }
    }

    private func icon(for path: String) -> String {
        if path.hasSuffix(".h") { return "chevron.left.forwardslash.chevron.right" }
        if path.hasSuffix(".m") || path.hasSuffix(".x") || path.hasSuffix(".mm") { return "curlybraces" }
        if path.hasSuffix(".plist") || path.hasSuffix(".json") { return "list.bullet.rectangle" }
        if path.lowercased().contains("makefile") || path.hasSuffix(".sh") { return "terminal" }
        return "doc.text"
    }
    private func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
}

/// One recovered source file in an editable text view, with save-back to the job.
struct ReconFileEditor: View {
    let jobID: String
    let path: String

    @State private var text = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var status: String?
    @State private var dirty = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let status { banner(status, .dtAccent) }
            if let error { banner(error, .red) }
            if loading {
                Spacer(); ProgressView("Loading…"); Spacer()
            } else {
                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white)
                    .scrollContentBackground(.hidden)
                    .background(Color.black)
                    .focused($focused)
                    .onChange(of: text) { _ in dirty = true; status = nil }
                    .padding(.horizontal, 6)
            }
        }
        .background(Color.black)
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { save() } label: {
                    if saving { ProgressView() } else { Text("Save").bold() }
                }.disabled(saving || loading || !dirty)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer(); Button("Done") { focused = false }
            }
        }
        .task { await load() }
        .preferredColorScheme(.dark)
    }

    private func banner(_ t: String, _ c: Color) -> some View {
        Text(t).font(.caption).foregroundStyle(c)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(c.opacity(0.1))
    }

    private func load() async {
        loading = true; error = nil
        do { text = try await ReconstructAPI.readFile(jobID: jobID, path: path); dirty = false }
        catch { self.error = "Couldn't open \(path): \(error.localizedDescription)" }
        loading = false
    }

    private func save() {
        saving = true; error = nil; status = nil
        Task {
            do {
                try await ReconstructAPI.writeFile(jobID: jobID, path: path, text: text)
                dirty = false; status = "Saved. Build the dylib to compile your changes."
            } catch { self.error = "Couldn't save: \(error.localizedDescription)" }
            saving = false
        }
    }
}

/// Presents the recovered-project editor on the top-most controller, so it layers over the chat sheet cleanly.
enum ReconEditorPresenter {
    static func present(jobID: String, dylibName: String) {
        let host = UIHostingController(rootView: ReconEditorView(jobID: jobID, dylibName: dylibName))
        host.overrideUserInterfaceStyle = .dark
        guard let top = DocumentPickerPresenter.topViewController() else { return }
        top.present(host, animated: true)
    }
}
