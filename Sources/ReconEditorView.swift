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
    @State private var buildError: String?
    @State private var navPath: [String] = []
    @State private var jump: String?
    @State private var showEvidence = false
    @State private var changed: Set<String> = []
    @State private var badFiles: [String: Int] = [:]   // path -> error count from the last build

    var body: some View {
        NavigationStack(path: $navPath) {
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
                        if let buildError {
                            Section {
                                Text(buildError).font(.caption).foregroundStyle(.red)
                                Button("Dismiss") { self.buildError = nil }.font(.caption)
                            }
                        }
                        if building {
                            Section {
                                HStack(spacing: 8) { ProgressView().scaleEffect(0.8); Text(buildLine.isEmpty ? "Building dylib…" : buildLine).font(.caption).lineLimit(2) }
                            }
                        }
                        ForEach(visibleFiles) { f in
                            NavigationLink(value: f.path) {
                                HStack {
                                    Image(systemName: icon(for: f.path)).font(.caption).foregroundStyle(Color.dtAccent)
                                    Text(f.path).font(.system(size: 13, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    if let n = badFiles[f.path], n > 0 {
                                        Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                            .padding(.horizontal, 6).padding(.vertical, 2).background(Color.red, in: Capsule())
                                    }
                                    if changed.contains(f.path) {
                                        Circle().fill(Color.orange).frame(width: 7, height: 7)
                                    }
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
                ReconFileEditor(jobID: jobID, path: path, building: $building, buildLine: $buildLine, buildError: $buildError, jump: $jump,
                                 knownFiles: visibleFiles.map { $0.path },
                                 openFile: { p, line in jump = line.map { "#\($0)" }; navPath = [p] },
                                 onBuild: { rebuild() })
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showEvidence = true } label: { Image(systemName: "gauge.with.dots.needle.67percent") }
                        .disabled(loading)
                    Button { rebuild() } label: {
                        if building { ProgressView() } else { Label("Build dylib", systemImage: "hammer.fill") }
                    }.disabled(building || loading)
                }
            }
            .sheet(isPresented: $showEvidence) {
                ReconEvidenceView(jobID: jobID, fileFilter: nil) { rec in
                    if let f = rec.file { jump = rec.label; navPath = [f] }
                }
            }
            .task { await load() }
            .onChange(of: navPath) { _ in Task { await refreshMeta() } }
            .onChange(of: building) { b in if !b { Task { await refreshMeta() } } }
            .preferredColorScheme(.dark)
            .tint(.dtAccent)
        }
    }

    /// generated files only: hide the engine's `.raw/` twins and other dot-folders
    private var visibleFiles: [ReconstructAPI.DecompFile] {
        files.filter { !$0.path.hasPrefix(".") }
    }

    private func load() async {
        loading = true; error = nil
        do { files = try await ReconstructAPI.files(jobID: jobID) }
        catch { self.error = "Couldn't load the recovered project: \(error.localizedDescription)" }
        loading = false
        await refreshMeta()
    }

    /// which files differ from what the engine generated, and which failed the last build
    private func refreshMeta() async {
        if let c = try? await ReconstructAPI.changes(jobID: jobID) {
            changed = Set(c.filter { $0.changed }.map { $0.path })
        }
        if let d = try? await ReconstructAPI.diagnostics(jobID: jobID) {
            var m: [String: Int] = [:]
            for f in files { let n = d.errorCount(for: f.path); if n > 0 { m[f.path] = n } }
            badFiles = m
        }
    }

    private func rebuild() {
        building = true; buildLine = ""; buildError = nil
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
                self.buildError = "Build failed: \(error.localizedDescription)"
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

private enum EditorSheet: Identifiable {
    case diff, problems, evidence, ai
    var id: Int { switch self { case .diff: return 0; case .problems: return 1; case .evidence: return 2; case .ai: return 3 } }
}

/// One recovered source file in a real code editor (syntax highlighting, line numbers, find/replace, undo/redo,
/// diff against the generated version, build problems, per-function evidence), with save-back and one-tap save + build.
struct ReconFileEditor: View {
    let jobID: String
    let path: String
    @Binding var building: Bool
    @Binding var buildLine: String
    @Binding var buildError: String?
    @Binding var jump: String?
    let knownFiles: [String]
    let openFile: (String, Int?) -> Void
    let onBuild: () -> Void

    @StateObject private var ctl = CodeEditorController()
    @State private var initialText = ""
    @State private var serverBaseline: String?
    @State private var loading = true
    @State private var loadFailed = false
    @State private var saving = false
    @State private var error: String?
    @State private var status: String?
    @State private var dirty = false
    @State private var savedEdit = false
    @State private var built = false
    @State private var diag: ReconstructAPI.Diagnostics?
    @State private var sheet: EditorSheet?
    @State private var aiSymbol: String?
    @State private var aiSelection: (text: String, line: Int)?
    @State private var showFind = false
    @State private var replaceText = ""
    @State private var showGoTo = false
    @State private var goToText = ""
    @FocusState private var findFocused: Bool

    private var language: CodeLanguage { CodeLanguage.detect(path) }
    private var errorCount: Int { diag?.errorCount(for: path) ?? 0 }
    private var problemCount: Int { diag?.items(for: path).count ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            if let status { banner(status, .dtAccent) }
            if let error { banner(error, .red) }
            if let buildError { banner(buildError, .red).onTapGesture { self.buildError = nil } }
            if building { banner(buildLine.isEmpty ? "Building dylib…" : buildLine, .orange) }
            if showFind { findBar }
            if loading {
                Spacer(); ProgressView("Loading…"); Spacer()
            } else if loadFailed {
                Spacer()
                Button("Retry") { Task { await load() } }
                Spacer()
            } else {
                CodeEditorView(initialText: initialText, language: language, controller: ctl) {
                    dirty = true; status = nil; built = false
                }
                .overlay(alignment: .bottom) { floatingBar.padding(.bottom, 14) }
                statusBar
            }
        }
        .background(Color.black)
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await performSave() } } label: {
                    if saving { ProgressView() } else { Text("Save").bold() }
                }.disabled(saving || loading || !dirty)
            }
        }
        .alert("Go to line", isPresented: $showGoTo) {
            TextField("Line", text: $goToText).keyboardType(.numberPad)
            Button("Go") { if let n = Int(goToText) { ctl.goTo(line: n) }; goToText = "" }
            Button("Cancel", role: .cancel) { goToText = "" }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .diff:
                ReconDiffView(path: path, baseline: serverBaseline ?? initialText, ctl: ctl) { dirty = true; status = nil }
            case .problems:
                ReconProblemsView(path: path, diag: diag) { line in ctl.goTo(line: line) }
            case .evidence:
                ReconEvidenceView(jobID: jobID, fileFilter: path, onOpen: { rec in ctl.jump(toSymbol: rec.label) },
                                  onAsk: { rec in aiSymbol = rec.label; aiSelection = nil; sheet = .ai })
            case .ai:
                ReconAIView(jobID: jobID, file: path, symbol: aiSymbol, selection: aiSelection?.text, selectionLine: aiSelection?.line,
                            knownFiles: knownFiles,
                            onOpenFile: { target, line in openFromAI(target, line) }) { touched in
                    if touched.contains(path) { Task { await reloadFromServer() } }
                }
            }
        }
        .onChange(of: ctl.query) { _ in ctl.updateFind() }
        .onChange(of: ctl.caseSensitive) { _ in ctl.updateFind() }
        .onChange(of: ctl.useRegex) { _ in ctl.updateFind() }
        .onChange(of: building) { b in
            if b { built = false } else { Task { await loadDiag(); built = (buildError == nil && errorCount == 0) } }
        }
        .task {
            await load()
            await loadDiag()
            if let j = jump {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if j.hasPrefix("#"), let n = Int(j.dropFirst()) { ctl.goTo(line: n) } else { ctl.jump(toSymbol: j) }
                jump = nil
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: pieces

    private var floatingBar: some View {
        HStack(spacing: 0) {
            fb("magnifyingglass", on: showFind) { toggleFind() }
            fb("arrow.uturn.backward", enabled: ctl.canUndo) { ctl.undo() }
            fb("arrow.uturn.forward", enabled: ctl.canRedo) { ctl.redo() }
            Menu {
                Button { Task { await openDiff() } } label: { Label("Diff vs generated", systemImage: "plus.forwardslash.minus") }
                Button { sheet = .problems } label: { Label("Problems (\(problemCount))", systemImage: "exclamationmark.triangle") }
                Button { sheet = .evidence } label: { Label("Function evidence", systemImage: "gauge.with.dots.needle.67percent") }
                Button { Task { await openAI() } } label: { Label("Ask Ai-Decrypt…", systemImage: "sparkles") }
                Button { showGoTo = true } label: { Label("Go to line…", systemImage: "arrow.down.to.line") }
            } label: {
                Image(systemName: errorCount > 0 ? "exclamationmark.circle.fill" : "ellipsis.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 34)
                    .foregroundStyle(errorCount > 0 ? Color.red : Color.white)
            }
            Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 20).padding(.horizontal, 3)
            fb(dirty ? "square.and.arrow.down.fill" : "square.and.arrow.down", on: dirty, enabled: dirty && !saving) {
                Task { await performSave() }
            }
            Button { buildTapped() } label: {
                Group {
                    if building { ProgressView() } else { Image(systemName: "hammer.fill") }
                }
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 34)
                .foregroundStyle(Color.dtAccent)
            }.disabled(building || saving)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }

    private func fb(_ icon: String, on: Bool = false, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 34)
                .foregroundStyle(on ? Color.dtAccent : Color.white)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    /// Original → Modified → Saved → Building → Built / N errors
    private var fileChip: (String, Color) {
        if building { return ("Building…", .orange) }
        if errorCount > 0 { return ("\(errorCount) error\(errorCount == 1 ? "" : "s")", .red) }
        if dirty { return ("Modified", .orange) }
        if built { return ("Built", .green) }
        if savedEdit { return ("Saved", Color.dtAccent) }
        return ("Original", .secondary)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("Ln \(ctl.line), Col \(ctl.column)")
            Text("\(ctl.lineCount) lines")
            Text(language.label)
            Spacer()
            Text(fileChip.0).bold().foregroundStyle(fileChip.1)
            Button { ctl.fontSize = max(9, ctl.fontSize - 1) } label: { Text("A−").bold() }
            Button { ctl.fontSize = min(24, ctl.fontSize + 1) } label: { Text("A+").bold() }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(white: 0.07))
    }

    private var countLabel: String {
        if ctl.query.isEmpty { return "" }
        if ctl.regexInvalid { return "bad regex" }
        return ctl.matchCount == 0 ? "0" : "\(ctl.matchIndex)/\(ctl.matchCount)"
    }

    private var findBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find", text: $ctl.query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($findFocused).submitLabel(.search)
                    .onSubmit { ctl.next(); findFocused = true }
                Text(countLabel).font(.caption.monospacedDigit())
                    .foregroundStyle(ctl.regexInvalid ? Color.red : Color.secondary)
                Button { ctl.prev() } label: { Image(systemName: "chevron.up") }
                Button { ctl.next() } label: { Image(systemName: "chevron.down") }
                Button { closeFind() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            }
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                TextField("Replace", text: $replaceText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                chip("Aa", on: ctl.caseSensitive) { ctl.caseSensitive.toggle() }
                chip(".*", on: ctl.useRegex) { ctl.useRegex.toggle() }
                Button("Replace") { ctl.replaceCurrent(with: replaceText) }.font(.caption.bold())
                Button("All") { ctl.replaceAll(with: replaceText) }.font(.caption.bold())
            }
        }
        .font(.system(size: 14))
        .padding(8)
        .background(Color(white: 0.11))
    }

    private func chip(_ t: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 12, weight: .bold, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(on ? Color.dtAccent.opacity(0.35) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func banner(_ t: String, _ c: Color) -> some View {
        Text(t).font(.caption).foregroundStyle(c)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(c.opacity(0.1))
    }

    // MARK: actions

    private func toggleFind() {
        showFind.toggle()
        ctl.findActive = showFind
        if showFind {
            ctl.prefillFromSelection()
            ctl.updateFind()
            findFocused = true
        } else {
            ctl.updateFind()
        }
    }

    private func closeFind() {
        showFind = false
        ctl.findActive = false
        findFocused = false
        ctl.updateFind()
        ctl.focus()
    }

    private func load() async {
        loading = true; loadFailed = false; error = nil
        do {
            initialText = try await ReconstructAPI.readFile(jobID: jobID, path: path); dirty = false
            serverBaseline = try? await ReconstructAPI.original(jobID: jobID, path: path)
            savedEdit = serverBaseline != nil && serverBaseline != initialText
        } catch {
            self.error = "Couldn't open \(path): \(error.localizedDescription)"
            loadFailed = true
        }
        loading = false
    }

    private func loadDiag() async {
        guard let d = try? await ReconstructAPI.diagnostics(jobID: jobID) else { return }
        diag = d
        var m: [Int: Int] = [:]
        for it in d.items(for: path) { m[it.line] = max(m[it.line] ?? 0, it.sev == "error" ? 2 : 1) }
        ctl.setMarkers(m)
    }

    /// The assistant works on the saved file on the server, so save first and hand it whatever is selected.
    /// A file name tapped in an Ai-Decrypt reply: same file → jump to the line; another file → close the sheet and open it.
    private func openFromAI(_ target: String, _ line: Int?) {
        sheet = nil
        if target == path {
            if let l = line { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { ctl.goTo(line: l) } }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openFile(target, line) }
        }
    }

    private func openAI() async {
        if dirty { guard await performSave() else { return } }
        aiSymbol = nil
        aiSelection = ctl.selectionInfo()
        sheet = .ai
    }

    /// after an Ai-Decrypt patch was applied or reverted: load the new text into the editor (it is already saved server-side)
    private func reloadFromServer() async {
        guard let t = try? await ReconstructAPI.readFile(jobID: jobID, path: path) else { return }
        ctl.replaceAllText(t)
        dirty = false
        built = false
        initialText = t
        if let b = try? await ReconstructAPI.original(jobID: jobID, path: path) { serverBaseline = b }
        savedEdit = serverBaseline != nil && serverBaseline != t
        status = "Updated by Ai-Decrypt."
        await loadDiag()
    }

    private func openDiff() async {
        if serverBaseline == nil, let b = try? await ReconstructAPI.original(jobID: jobID, path: path) { serverBaseline = b }
        sheet = .diff
    }

    @discardableResult
    private func performSave() async -> Bool {
        saving = true; error = nil; status = nil
        defer { saving = false }
        do {
            try await ReconstructAPI.writeFile(jobID: jobID, path: path, text: ctl.text())
            dirty = false; status = "Saved."
            // the first save captures the generated version on the server as the diff baseline
            if serverBaseline == nil { serverBaseline = initialText }
            savedEdit = ctl.text() != (serverBaseline ?? initialText)
            return true
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
            return false
        }
    }

    private func buildTapped() {
        Task {
            if dirty { guard await performSave() else { return } }
            onBuild()
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
