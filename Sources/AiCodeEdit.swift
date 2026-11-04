import SwiftUI
import UIKit

// MARK: - edit_code tool

/// Lets the chat model change the code of a reconstructed project: it calls `edit_code`, the server's patch engine
/// writes a reviewed patch, and the chat shows the diff with Apply / Reject. Nothing is written until Apply.
enum AiCodeEdit {
    static let name = "edit_code"

    static let schema: [String: Any] = [
        "type": "function",
        "function": [
            "name": name,
            "description": "Changes the source code of the reconstructed project already in this chat (add a feature, fix a bug, rename, refactor). It does NOT write anything: it prepares a patch and the chat shows the exact diff with an Apply button for the person. Use it whenever they ask to add, change or fix code. Describe the change fully in `request`. After it runs, do not say the change is applied.",
            "parameters": [
                "type": "object",
                "properties": [
                    "request": ["type": "string", "description": "What to change, in plain words, with every detail the person gave."],
                    "file": ["type": "string", "description": "Optional path of the file to change, if the person named one."],
                ],
                "required": ["request"],
            ] as [String: Any],
        ] as [String: Any],
    ]

    static func args(_ arguments: String) -> (request: String, file: String?) {
        guard let d = arguments.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return ("", nil) }
        let r = ((o["request"] as? String) ?? (o["message"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let f = (o["file"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (r, (f?.isEmpty ?? true) ? nil : f)
    }
}

extension AiDecryptViewModel {
    /// The newest reconstructed project in this chat (job id + library name), if any.
    var latestReconProject: (jobID: String, name: String)? {
        for m in messages.reversed() {
            if case .reconResults(let rs)? = m.card, let r = rs.last(where: { !$0.jobID.isEmpty }) { return (r.jobID, r.dylibName) }
            if case .patch(let job, _, let name)? = m.card { return (job, name) }
        }
        return nil
    }

    /// Asks the server's patch engine for a change and puts the result on `messages[index]` as a diff card.
    func proposeCodeEdit(request: String, file: String?, into index: Int) async -> String {
        guard let project = latestReconProject else {
            return "There is no reconstructed project in this chat yet, so there is no code to change. Tell the person to reconstruct a library first."
        }
        guard index < messages.count else { return "Cancelled." }
        messages[index].content = "Reading \(project.name)…"
        do {
            let result = try await ReconstructAPI.aiAsk(
                jobID: project.jobID, message: request, action: "chat", file: file, symbol: nil, selection: nil, selectionLine: nil,
                onStart: { _ in },
                progress: { [weak self] p in
                    guard let self, index < self.messages.count else { return }
                    let tail = p.tokens > 0 ? " · \(p.tokens) tokens" : ""
                    self.messages[index].content = "Writing the patch…\(tail)"
                })
            guard index < messages.count else { return "" }
            messages[index].toolCalls = nil
            if let patch = result.patch {
                var wrote = false
                // write it into the project's files right away unless the server flagged it for a closer look
                if AiPrefs.autoApplyCode, patch.status == "proposed", patch.inference != true, patch.stale == nil,
                   (try? await ReconstructAPI.aiApply(jobID: project.jobID, id: patch.id)) != nil { wrote = true }
                guard index < messages.count else { return "" }
                let fallback = wrote ? "Done. The change is written into the project files; the diff is below and Revert undoes it."
                                     : "Here's the change. Review the diff, then tap Apply."
                messages[index].content = result.reply.isEmpty ? fallback : result.reply
                messages[index].card = .patch(jobID: project.jobID, patchID: patch.id, name: project.name)
            } else {
                messages[index].content = result.reply.isEmpty ? "I couldn't find a safe change to make." : result.reply
            }
            return ""
        } catch is CancellationError {
            if index < messages.count { messages[index].content = "Cancelled. Nothing was changed."; messages[index].toolCalls = nil }
            return ""
        } catch {
            if index < messages.count {
                messages[index].content = "Couldn't prepare that change: \(error.localizedDescription)"
                messages[index].toolCalls = nil
            }
            return ""
        }
    }
}

// MARK: - Diff card in the chat

struct AiPatchCard: View {
    let jobID: String
    let patchID: String
    let name: String
    /// nesting level of a follow-up fix after a failed build (0 = the original edit)
    var depth = 0
    /// a fix card applies itself and rebuilds straight away
    var autoBuild = false

    @State private var patch: ReconstructAPI.AIPatch?
    @State private var working = false
    @State private var error: String?
    @State private var review = false
    @State private var expanded = false
    @State private var offerForce = false
    @State private var building = false
    @State private var buildLine = ""
    @State private var builtName: String?
    @State private var fixing = false
    @State private var fixPatchID: String?
    @State private var buildLog = ""
    @State private var fixReply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let p = patch {
                HStack(spacing: 8) {
                    Image(systemName: icon(p)).foregroundStyle(tint(p))
                    Text(p.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                    Spacer(minLength: 0)
                    Text(label(p)).font(.caption2.bold()).foregroundStyle(tint(p))
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(tint(p).opacity(0.15)))
                }
                if let s = p.summary, !s.isEmpty { Text(s).font(.footnote).foregroundStyle(.secondary) }
                if p.inference == true {
                    Label("Includes the model's own judgement. Read the diff first.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let st = p.stale { Text("Out of date: \(st)").font(.caption).foregroundStyle(.red) }
                if let r = p.blockReason, p.status == "blocked" { Text(r).font(.caption).foregroundStyle(.red) }

                ForEach(p.changes ?? [], id: \.self) { c in fileDiff(c) }

                if fixing { HStack(spacing: 8) { ProgressView().scaleEffect(0.8); Text(buildLine.isEmpty ? "Build failed. Working out a fix…" : buildLine).font(.caption).foregroundStyle(.secondary) } }
                if let f = fixPatchID {
                    if !fixReply.isEmpty { Text(fixReply).font(.footnote).foregroundStyle(.white.opacity(0.85)) }
                    AiPatchCard(jobID: jobID, patchID: f, name: name, depth: depth + 1, autoBuild: true).id(f)
                }
                if building { Text(buildLine.isEmpty ? "Starting the build…" : buildLine).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2) }
                if let b = builtName {
                    HStack(spacing: 8) {
                        Label("Built and repackaged", systemImage: "shippingbox.fill").font(.footnote.bold()).foregroundStyle(Color.dtAccent)
                        Spacer(minLength: 0)
                        Button { Task { await share(ReconstructAPI.dylibDownloadPath(jobID: jobID), b) } } label: {
                            Text(".dylib").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 7).aiGlass(Capsule())
                        }
                        Button { Task { await share(ReconstructAPI.zipDownloadPath(jobID: jobID), name.replacingOccurrences(of: ".", with: "_") + "-recovered.zip") } } label: {
                            Text("Project .zip").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 7).aiGlass(Capsule())
                        }
                    }
                }
                if let e = error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(8) }

                HStack(spacing: 8) {
                    if working { ProgressView().scaleEffect(0.8) }
                    if p.status == "proposed" {
                        Button { Task { await apply() } } label: {
                            Label("Apply", systemImage: "checkmark").font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.dtOnAccent).padding(.horizontal, 16).padding(.vertical, 9)
                                .background(Capsule().fill(Color.dtAccent))
                        }.disabled(working || p.stale != nil)
                        Button { Task { await reject() } } label: {
                            Text("Reject").font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 9).aiGlass(Capsule())
                        }.disabled(working)
                    } else if p.status == "applied" {
                        Button { Task { await revert() } } label: {
                            Label(offerForce ? "Revert anyway" : "Revert", systemImage: "arrow.uturn.backward")
                                .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 9).aiGlass(Capsule())
                        }.disabled(working)
                        Button { ReconEditorPresenter.present(jobID: jobID, dylibName: name) } label: {
                            Label("Open editor", systemImage: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 9).aiGlass(Capsule())
                        }
                        if builtName == nil {
                            Button { Task { await build() } } label: {
                                Label(building ? "Building…" : "Build", systemImage: "hammer")
                                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.dtOnAccent)
                                    .padding(.horizontal, 16).padding(.vertical, 9).background(Capsule().fill(Color.dtAccent))
                            }.disabled(building || working)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { review = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white).aiGlassCircle(36)
                    }
                }
            } else if let e = error {
                Text(e).font(.caption).foregroundStyle(.red)
            } else {
                HStack(spacing: 8) { ProgressView().scaleEffect(0.8); Text("Loading the diff…").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.115)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5))
        .task {
            if patch == nil { await load() }
            guard let p = patch, autoBuild || AiPrefs.autoBuild else { return }
            if autoBuild, p.status == "proposed", AiPrefs.autoApplyCode, p.inference != true, p.stale == nil { await apply() }
            if patch?.status == "applied", builtName == nil, !building { await build() }
        }
        .sheet(isPresented: $review) {
            if let p = patch {
                ReconPatchReview(jobID: jobID, patch: p) { updated, _ in
                    patch = ReconstructAPI.AIPatch(id: updated.id, title: updated.title, summary: updated.summary, model: updated.model,
                                                   inference: updated.inference, evidence: updated.evidence, status: updated.status,
                                                   blockReason: updated.blockReason, files: updated.files,
                                                   changes: updated.changes ?? p.changes, stale: updated.stale)
                }
            }
        }
    }

    // MARK: pieces

    private func fileDiff(_ c: ReconstructAPI.AIPatchChange) -> some View {
        let oldL = LineDiff.lines(c.old), newL = LineDiff.lines(c.neu)
        let hunks = LineDiff.hunks(old: oldL, new: newL)
        let added = hunks.reduce(0) { $0 + $1.newLines.count }, removed = hunks.reduce(0) { $0 + $1.oldLines.count }
        let limit = expanded ? 400 : 14
        var rows: [(String, String)] = []
        for h in hunks {
            for l in h.oldLines { rows.append(("−", l)) }
            for l in h.newLines { rows.append(("+", l)) }
            if rows.count > limit { break }
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(c.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
                Text("+\(added)").font(.caption.monospaced().bold()).foregroundStyle(.green)
                Text("−\(removed)").font(.caption.monospaced().bold()).foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.prefix(limit).enumerated()), id: \.offset) { _, r in
                    HStack(alignment: .top, spacing: 6) {
                        Text(r.0).font(.system(size: 11, weight: .bold, design: .monospaced)).frame(width: 10)
                        Text(r.1.isEmpty ? " " : r.1).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(r.0 == "+" ? Color.green : Color.red)
                    .padding(.vertical, 1.5).padding(.horizontal, 6)
                    .background((r.0 == "+" ? Color.green : Color.red).opacity(0.08))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            if rows.count > 14 || expanded {
                Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                    Text(expanded ? "Show less" : "Show more").font(.caption.bold()).foregroundStyle(Color.dtAccent)
                }
            }
        }
    }

    private func icon(_ p: ReconstructAPI.AIPatch) -> String {
        switch p.status { case "applied": return "checkmark.circle.fill"; case "rejected", "reverted": return "xmark.circle"
        case "blocked": return "exclamationmark.octagon.fill"; default: return "plus.forwardslash.minus" }
    }
    private func tint(_ p: ReconstructAPI.AIPatch) -> Color {
        switch p.status { case "applied": return .dtAccent; case "blocked": return .red; case "rejected", "reverted": return .secondary; default: return .white }
    }
    private func label(_ p: ReconstructAPI.AIPatch) -> String {
        switch p.status { case "proposed": return "Needs your OK"; case "applied": return "Applied"; case "rejected": return "Rejected"
        case "reverted": return "Reverted"; case "blocked": return "Blocked"; default: return p.status.capitalized }
    }

    // MARK: actions

    private func load() async {
        do { patch = try await ReconstructAPI.aiPatch(jobID: jobID, id: patchID) }
        catch { self.error = error.localizedDescription }
    }

    private func keepDiff(_ p: ReconstructAPI.AIPatch) {
        let old = patch?.changes
        patch = ReconstructAPI.AIPatch(id: p.id, title: p.title, summary: p.summary, model: p.model, inference: p.inference, evidence: p.evidence,
                                       status: p.status, blockReason: p.blockReason, files: p.files, changes: p.changes ?? old, stale: p.stale)
    }

    private func apply() async {
        working = true; error = nil; defer { working = false }
        do { keepDiff(try await ReconstructAPI.aiApply(jobID: jobID, id: patchID)) }
        catch { self.error = error.localizedDescription }
    }
    private func reject() async {
        working = true; error = nil; defer { working = false }
        do { keepDiff(try await ReconstructAPI.aiReject(jobID: jobID, id: patchID)) }
        catch { self.error = error.localizedDescription }
    }
    private func build() async {
        building = true; error = nil; buildLine = ""; buildLog = ""; defer { building = false }
        do {
            builtName = try await ReconstructAPI.build(jobID: jobID) { line in buildLine = line; buildLog += line + "\n" }
        } catch {
            self.error = "Build failed: " + error.localizedDescription
            await fixAfterFailure(error.localizedDescription)
        }
    }

    /// Asks the patch engine to fix the compiler errors, then shows its patch as a nested card that applies and rebuilds.
    private func fixAfterFailure(_ why: String) async {
        guard depth < 3, !fixing else { return }
        fixing = true; defer { fixing = false }
        let log = String(buildLog.suffix(1800))
        let ask = "The build failed. Fix the compiler/linker errors with a real, minimal correction that keeps the original behaviour: " +
                  "do not delete or stub out functions, do not comment code out and do not silence warnings just to make it compile. " +
                  "Explain the cause in the reply.\n\nBuild output:\n\(why)\n\(log)"
        do {
            let r = try await ReconstructAPI.aiAsk(jobID: jobID, message: ask, action: "fix", file: nil, symbol: nil, selection: nil, selectionLine: nil,
                                                  onStart: { _ in }, progress: { p in buildLine = "Writing a fix… \(p.tokens) tokens" })
            fixReply = r.reply
            if let fp = r.patch { fixPatchID = fp.id } else { self.error = "Build failed, and no safe fix was found: " + r.reply }
        } catch { self.error = "Build failed, and the fix request failed: " + error.localizedDescription }
        buildLine = ""
    }
    private func share(_ path: String, _ file: String) async {
        do {
            let url = try await FileDownloader().download(path: path, name: file) { _ in }
            SharePresenter.present(url)
        } catch { self.error = error.localizedDescription }
    }
    private func revert() async {
        working = true; error = nil; defer { working = false }
        do { keepDiff(try await ReconstructAPI.aiRevert(jobID: jobID, id: patchID, force: offerForce)); offerForce = false; builtName = nil }
        catch {
            self.error = error.localizedDescription
            if error.localizedDescription.contains("edited after") { offerForce = true }
        }
    }
}

// MARK: - Edit history (every patch made to this project, with Revert)

struct AiEditHistorySheet: View {
    let jobID: String
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var patches: [ReconstructAPI.AIPatch] = []
    @State private var loading = true
    @State private var error: String?
    @State private var opening: String?
    @State private var review: ReconstructAPI.AIPatch?

    var body: some View {
        NavigationStack {
            List {
                if loading { HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) } }
                if let e = error { Text(e).font(.footnote).foregroundStyle(.red) }
                if !loading && patches.isEmpty && error == nil {
                    Text("No code edits yet. Ask Ai-Decrypt to add or fix something in \(name).").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(patches) { p in
                    Button { Task { await open(p) } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon(p.status)).foregroundStyle(color(p.status)).frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.title).font(.system(size: 16, weight: .medium)).foregroundStyle(.white).lineLimit(2)
                                Text((p.files ?? []).joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            if opening == p.id { ProgressView() }
                            else { Text(p.status.capitalized).font(.caption.bold()).foregroundStyle(color(p.status)) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("Code edits").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .refreshable { await load() }
            .sheet(item: $review) { p in
                ReconPatchReview(jobID: jobID, patch: p) { _, _ in Task { await load() } }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.dtAccent)
    }

    private func icon(_ s: String) -> String {
        switch s { case "applied": return "checkmark.circle.fill"; case "reverted": return "arrow.uturn.backward.circle"
        case "rejected": return "xmark.circle"; case "blocked": return "exclamationmark.octagon"; default: return "clock" }
    }
    private func color(_ s: String) -> Color {
        switch s { case "applied": return .dtAccent; case "blocked": return .red; case "proposed": return .orange; default: return .secondary }
    }

    private func load() async {
        do { patches = try await ReconstructAPI.aiState(jobID: jobID).patches.reversed(); error = nil }
        catch { self.error = error.localizedDescription }
        loading = false
    }
    private func open(_ p: ReconstructAPI.AIPatch) async {
        opening = p.id; defer { opening = nil }
        do { review = try await ReconstructAPI.aiPatch(jobID: jobID, id: p.id) }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: - AI server check (model + worker endpoints, from the server's own self-test)

struct AiServerHealthSheet: View {
    @Environment(\.dismiss) private var dismiss

    struct Probe: Decodable { var ok: Bool; var ms: Int?; var status: Int?; var error: String?; var multiSystemOk: Bool?; var url: String? }
    struct Report: Decodable { var at: Double?; var main: Probe?; var workers: [Probe]? }

    @State private var report: Report?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if loading { HStack { ProgressView(); Text("Testing the model server…").foregroundStyle(.secondary) } }
                if let e = error { Text(e).font(.footnote).foregroundStyle(.red) }
                if let m = report?.main {
                    Section("Main model") { probeRow("Ai-Decrypt", m) }
                    if m.multiSystemOk == false {
                        Section(footer: Text("This model's chat template accepts one system message only. The app already merges its notes into one, so this is just for your information.")) {
                            Label("Strict chat template", systemImage: "info.circle").foregroundStyle(.secondary)
                        }
                    }
                }
                if let w = report?.workers, !w.isEmpty {
                    Section("Helper models") { ForEach(Array(w.enumerated()), id: \.offset) { i, p in probeRow(p.url ?? "worker \(i + 1)", p) } }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("AI server check").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Re-test") { Task { await run() } }.disabled(loading) }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await run() }
        }
        .preferredColorScheme(.dark)
        .tint(.dtAccent)
    }

    private func probeRow(_ title: String, _ p: Probe) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: p.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(p.ok ? Color.dtAccent : .red)
                Text(title)
                Spacer()
                if let ms = p.ms { Text("\(ms) ms").font(.caption.monospaced()).foregroundStyle(.secondary) }
            }
            if !p.ok, let e = p.error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(4) }
        }
    }

    private func run() async {
        loading = true; error = nil; defer { loading = false }
        do { report = try await Api.shared.get("/api/ai/health?fresh=1") }
        catch { self.error = error.localizedDescription }
    }
}
