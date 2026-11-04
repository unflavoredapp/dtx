import SwiftUI
import UIKit

// MARK: - API

extension ReconstructAPI {
    struct AIPatchChange: Decodable, Hashable { let path: String; let old: String; let neu: String }
    struct AIPatch: Decodable, Identifiable {
        let id: String
        let title: String
        let summary: String?
        let model: String?
        let inference: Bool?
        let evidence: [String]?
        var status: String
        let blockReason: String?
        let files: [String]?
        let changes: [AIPatchChange]?
        let stale: String?
    }
    struct AIMsg: Decodable { let role: String; let text: String; let patch: String?; let err: Int? }
    struct AILLM: Decodable { let configured: Bool }
    struct AIState: Decodable { let llm: AILLM; let patches: [AIPatch]; let chat: [AIMsg] }
    struct AIResult: Decodable { let reply: String; let patch: AIPatch? }

    private struct AIStarted: Decodable { let job: String }
    private struct AIJob: Decodable { let state: String; let seconds: Int?; let error: String?; let result: AIResult? }
    private struct AIPatchReply: Decodable { let patch: AIPatch }

    static func aiState(jobID: String) async throws -> AIState {
        try await Api.shared.get("\(base)/jobs/\(jobID)/ai")
    }

    /// Starts a request and polls until the model has answered (a local model can take minutes).
    static func aiAsk(jobID: String, message: String, action: String, file: String?, symbol: String?,
                      selection: String?, selectionLine: Int?, progress: @escaping (Int) -> Void) async throws -> AIResult {
        var body: [String: Any] = ["message": message, "action": action]
        if let file { body["file"] = file }
        if let symbol { body["symbol"] = symbol }
        if let selection { body["selection"] = selection }
        if let selectionLine { body["selectionLine"] = selectionLine }
        let started: AIStarted = try await Api.shared.post("\(base)/jobs/\(jobID)/ai/chat", json: body)
        var misses = 0
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            do {
                let j: AIJob = try await Api.shared.get("\(base)/jobs/\(jobID)/ai/jobs/\(started.job)"); misses = 0
                if j.state == "running" { await MainActor.run { progress(j.seconds ?? 0) }; continue }
                if j.state == "error" { throw ApiError.server(j.error ?? "The request failed.", 0) }
                if let r = j.result { return r }
                throw ApiError.server("The assistant returned nothing.", 0)
            } catch let e as ApiError where e.status == 0 { throw e }
            catch { misses += 1; if misses > 30 { throw error } }
        }
    }

    static func aiPatch(jobID: String, id: String) async throws -> AIPatch {
        let r: AIPatchReply = try await Api.shared.get("\(base)/jobs/\(jobID)/ai/patches/\(id)")
        return r.patch
    }
    static func aiApply(jobID: String, id: String) async throws -> AIPatch {
        let r: AIPatchReply = try await Api.shared.post("\(base)/jobs/\(jobID)/ai/patches/\(id)/apply")
        return r.patch
    }
    static func aiRevert(jobID: String, id: String, force: Bool) async throws -> AIPatch {
        let r: AIPatchReply = try await Api.shared.post("\(base)/jobs/\(jobID)/ai/patches/\(id)/revert", json: ["force": force])
        return r.patch
    }
    static func aiReject(jobID: String, id: String) async throws -> AIPatch {
        let r: AIPatchReply = try await Api.shared.post("\(base)/jobs/\(jobID)/ai/patches/\(id)/reject")
        return r.patch
    }
}

// MARK: - Chat sheet

struct ReconAIView: View {
    let jobID: String
    let file: String
    let symbol: String?
    let selection: String?
    let selectionLine: Int?
    /// called with the paths an applied / reverted patch touched, so the editor can reload them
    let onChanged: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss

    private struct Bubble: Identifiable {
        let id = UUID()
        let role: String
        let text: String
        var patchID: String?
        var isError = false
    }

    @State private var bubbles: [Bubble] = []
    @State private var patches: [String: ReconstructAPI.AIPatch] = [:]
    @State private var configured = true
    @State private var input = ""
    @State private var busy = false
    @State private var elapsed = 0
    @State private var loadError: String?
    @State private var reviewing: ReconstructAPI.AIPatch?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                contextBar
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let loadError { Text(loadError).font(.caption).foregroundStyle(.red) }
                            if !configured {
                                Text("No model is connected on the server yet (OPTIMIZE_LLM_URL). Explanations and patches need one.")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            if bubbles.isEmpty && loadError == nil {
                                Text("Ask about this \(symbol == nil ? "file" : "function"), or tap a shortcut. Changes are always shown as a diff first — nothing is written until you press Apply.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            ForEach(bubbles) { b in bubble(b).id(b.id) }
                            if busy {
                                HStack(spacing: 8) { ProgressView(); Text("Thinking… \(elapsed)s").font(.caption).foregroundStyle(.secondary) }
                                    .id("busy")
                            }
                        }
                        .padding(14)
                    }
                    .onChange(of: bubbles.count) { _ in withAnimation { proxy.scrollTo(bubbles.last?.id, anchor: .bottom) } }
                    .onChange(of: busy) { b in if b { withAnimation { proxy.scrollTo("busy", anchor: .bottom) } } }
                }
                inputBar
            }
            .background(Color.black)
            .navigationTitle("Ai-Decrypt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } } }
            .sheet(item: $reviewing) { p in
                ReconPatchReview(jobID: jobID, patch: p) { updated, touched in
                    patches[updated.id] = updated
                    if !touched.isEmpty { onChanged(touched) }
                }
            }
            .task { await load() }
        }
        .preferredColorScheme(.dark)
        .tint(.dtAccent)
    }

    private var contextBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "scope").font(.caption)
            Text(symbol ?? (file as NSString).lastPathComponent).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            if selection != nil { Text("+ selection").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Color.dtAccent.opacity(0.25), in: Capsule()) }
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color(white: 0.08))
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    shortcut("Explain", "text.magnifyingglass") { send("Explain what this does and how reliable the reconstruction is.", action: "explain") }
                    shortcut("Fix build errors", "wrench.and.screwdriver") { send("Fix the build errors in this file.", action: "fix") }
                    shortcut("Improve readability", "sparkles") { send("Improve readability: meaningful names where the evidence supports them, no behaviour change.", action: "improve") }
                }
                .padding(.horizontal, 14)
            }
            HStack(spacing: 8) {
                TextField("Ask or describe a change…", text: $input, axis: .vertical)
                    .lineLimit(1...4).focused($focused)
                    .textInputAutocapitalization(.sentences)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                Button {
                    let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    input = ""; send(t, action: "chat")
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)).foregroundStyle(Color.dtAccent)
                }.disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 8)
        .background(Color(white: 0.08))
    }

    private func shortcut(_ t: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(t, systemImage: icon).font(.caption.bold())
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.1), in: Capsule())
        }.disabled(busy || !configured)
    }

    @ViewBuilder private func bubble(_ b: Bubble) -> some View {
        if b.role == "user" {
            HStack { Spacer(minLength: 40)
                Text(b.text).font(.callout).padding(10)
                    .background(Color.dtAccent.opacity(0.22), in: RoundedRectangle(cornerRadius: 14)) }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(b.text).font(.callout).foregroundStyle(b.isError ? Color.red : Color.white).textSelection(.enabled)
                if let pid = b.patchID, let p = patches[pid] { patchCard(p) }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func patchCard(_ p: ReconstructAPI.AIPatch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(p.title).font(.subheadline.bold())
                Spacer()
                Text(p.status.capitalized).font(.caption2.bold()).padding(.horizontal, 7).padding(.vertical, 2)
                    .background(statusColor(p.status).opacity(0.25), in: Capsule()).foregroundStyle(statusColor(p.status))
            }
            if let s = p.summary, !s.isEmpty { Text(s).font(.caption).foregroundStyle(.secondary) }
            if let f = p.files, !f.isEmpty {
                Text(f.joined(separator: ", ")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            }
            if p.inference == true {
                Label("Includes the model's own judgement, not only what the evidence shows", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if let ev = p.evidence, !ev.isEmpty {
                ForEach(ev.prefix(4), id: \.self) { e in Text("• " + e).font(.caption2).foregroundStyle(.secondary) }
            }
            if let why = p.blockReason, p.status == "blocked" { Text(why).font(.caption).foregroundStyle(.red) }
            Button { Task { await openReview(p) } } label: {
                Label(p.status == "proposed" ? "Review diff" : "View diff", systemImage: "plus.forwardslash.minus").font(.caption.bold())
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func statusColor(_ s: String) -> Color {
        switch s { case "applied": return .green; case "proposed": return Color.dtAccent; case "blocked": return .red; default: return .secondary }
    }

    // MARK: actions

    private func load() async {
        do {
            let st = try await ReconstructAPI.aiState(jobID: jobID)
            configured = st.llm.configured
            for p in st.patches { patches[p.id] = p }
            bubbles = st.chat.map { Bubble(role: $0.role, text: $0.text, patchID: $0.patch, isError: $0.err != nil) }
        } catch {
            loadError = "Couldn't reach the Ai-Decrypt service: \(error.localizedDescription)"
        }
    }

    private func openReview(_ p: ReconstructAPI.AIPatch) async {
        if p.changes != nil { reviewing = p; return }
        if let full = try? await ReconstructAPI.aiPatch(jobID: jobID, id: p.id) { patches[p.id] = full; reviewing = full }
    }

    private func send(_ text: String, action: String) {
        guard !busy else { return }
        bubbles.append(Bubble(role: "user", text: text))
        busy = true; elapsed = 0; focused = false
        Task {
            do {
                let r = try await ReconstructAPI.aiAsk(jobID: jobID, message: text, action: action, file: file, symbol: symbol,
                                                       selection: selection, selectionLine: selectionLine) { s in elapsed = s }
                var b = Bubble(role: "assistant", text: r.reply)
                if let p = r.patch { patches[p.id] = p; b.patchID = p.id }
                bubbles.append(b)
            } catch {
                bubbles.append(Bubble(role: "assistant", text: error.localizedDescription, isError: true))
            }
            busy = false
        }
    }
}

// MARK: - Patch review (diff → Apply / Reject / Revert)

struct ReconPatchReview: View {
    let jobID: String
    let onDone: (ReconstructAPI.AIPatch, [String]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var patch: ReconstructAPI.AIPatch
    @State private var working = false
    @State private var error: String?
    @State private var offerForce = false

    init(jobID: String, patch: ReconstructAPI.AIPatch, onDone: @escaping (ReconstructAPI.AIPatch, [String]) -> Void) {
        self.jobID = jobID; self.onDone = onDone
        _patch = State(initialValue: patch)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(patch.title).font(.headline)
                    if let s = patch.summary, !s.isEmpty { Text(s).font(.caption).foregroundStyle(.secondary) }
                    if patch.inference == true {
                        Label("Includes the model's own judgement. Read the diff before applying.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let st = patch.stale { Text("Out of date: \(st)").font(.caption).foregroundStyle(.red) }
                    if let e = error { Text(e).font(.caption).foregroundStyle(.red) }
                }
                ForEach(patch.changes ?? [], id: \.self) { c in
                    PatchFileDiff(change: c)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Review patch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if working { ProgressView() }
                    else if patch.status == "proposed" {
                        Button("Apply") { Task { await apply() } }.bold().disabled(patch.stale != nil)
                    } else if patch.status == "applied" {
                        Button(offerForce ? "Revert anyway" : "Revert") { Task { await revert() } }
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    if patch.status == "proposed" || patch.status == "blocked" {
                        Button("Reject", role: .destructive) { Task { await reject() } }.disabled(working)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.dtAccent)
    }

    private func apply() async {
        working = true; error = nil
        defer { working = false }
        do {
            let p = try await ReconstructAPI.aiApply(jobID: jobID, id: patch.id)
            patch = p
            onDone(p, p.files ?? [])
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func revert() async {
        working = true; error = nil
        defer { working = false }
        do {
            let p = try await ReconstructAPI.aiRevert(jobID: jobID, id: patch.id, force: offerForce)
            // keep the diff on screen: the revert reply carries no file contents
            patch = ReconstructAPI.AIPatch(id: p.id, title: p.title, summary: p.summary, model: p.model, inference: p.inference, evidence: p.evidence,
                                           status: p.status, blockReason: p.blockReason, files: p.files, changes: patch.changes, stale: nil)
            onDone(patch, patch.files ?? [])
            dismiss()
        } catch {
            self.error = error.localizedDescription
            if error.localizedDescription.contains("edited after") { offerForce = true }
        }
    }

    private func reject() async {
        working = true; error = nil
        defer { working = false }
        do {
            let p = try await ReconstructAPI.aiReject(jobID: jobID, id: patch.id)
            onDone(p, [])
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// One file's before/after as hunks with two lines of context.
struct PatchFileDiff: View {
    let change: ReconstructAPI.AIPatchChange

    var body: some View {
        let oldL = LineDiff.lines(change.old), newL = LineDiff.lines(change.neu)
        let hunks = LineDiff.hunks(old: oldL, new: newL)
        Section {
            ForEach(hunks) { h in
                VStack(alignment: .leading, spacing: 0) {
                    Text("Line \(h.newStart + 1)").font(.caption2.monospaced()).foregroundStyle(.secondary).padding(.bottom, 2)
                    ForEach(Array(before(h, newL).enumerated()), id: \.offset) { _, l in row(l, " ", .secondary) }
                    ForEach(Array(h.oldLines.enumerated()), id: \.offset) { _, l in row(l, "−", .red) }
                    ForEach(Array(h.newLines.enumerated()), id: \.offset) { _, l in row(l, "+", .green) }
                    ForEach(Array(after(h, newL).enumerated()), id: \.offset) { _, l in row(l, " ", .secondary) }
                }
            }
        } header: {
            Text(change.path).font(.caption.monospaced())
        }
    }

    private func before(_ h: DiffHunk, _ n: [String]) -> [String] {
        let s = max(0, h.newStart - 2); return s < h.newStart && h.newStart <= n.count ? Array(n[s..<h.newStart]) : []
    }
    private func after(_ h: DiffHunk, _ n: [String]) -> [String] {
        let e = h.newStart + h.newLines.count; return e < n.count ? Array(n[e..<min(n.count, e + 2)]) : []
    }
    private func row(_ t: String, _ mark: String, _ c: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(mark).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(c).frame(width: 10)
            Text(t.isEmpty ? " " : t).font(.system(size: 12, design: .monospaced)).foregroundStyle(c)
        }
        .padding(.vertical, 1)
        .background(c == .red ? Color.red.opacity(0.10) : c == .green ? Color.green.opacity(0.10) : Color.clear)
    }
}
