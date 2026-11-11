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

    /// Tokens used by this job's conversation, and the model's context window.
    struct AIUsage: Decodable, Equatable {
        var prompt: Int? = nil
        var completion: Int? = nil
        var lastPrompt: Int? = nil
        var ctx: Int? = nil
        var src: String? = nil          // api | tokenizer | estimate
        var used: Int { (prompt ?? 0) + (completion ?? 0) }
    }

    struct AIState: Decodable { let llm: AILLM; let patches: [AIPatch]; let chat: [AIMsg]; let usage: AIUsage? }
    struct AIResult: Decodable { let reply: String; let patch: AIPatch? }

    struct AIStep: Decodable, Hashable { let key: String; let label: String; let detail: String?; let ms: Int; let active: Bool }
    /// The code the server is about to send to the model.
    struct AISnippet: Decodable, Equatable { let path: String; let start: Int; let kind: String; let text: String; let more: Int? }

    struct AIProgress: Equatable {
        var seconds = 0
        var attempt = 1
        var tokens = 0
        var tps = 0.0
        var model: String? = nil
        var deep = false
        var stalled = false
        var sections: [String] = []
        var partial = ""
        var phase = ""
        var steps: [AIStep] = []
        var usage: AIUsage? = nil
    }

    struct AIStarted: Decodable { let job: String; let snippet: AISnippet?; let ctx: Int?; let usage: AIUsage? }

    private struct AIJob: Decodable {
        let state: String
        let error: String?
        let result: AIResult?
        let seconds: Int?
        let attempt: Int?
        let model: String?
        let deep: Bool?
        let tokens: Int?
        let tps: Double?
        let stalled: Bool?
        let sections: [String]?
        let partial: String?
        let phase: String?
        let steps: [AIStep]?
        let usage: AIUsage?

        var progress: AIProgress {
            AIProgress(seconds: seconds ?? 0, attempt: attempt ?? 1, tokens: tokens ?? 0, tps: tps ?? 0, model: model,
                       deep: deep ?? false, stalled: stalled ?? false, sections: sections ?? [], partial: partial ?? "",
                       phase: phase ?? "", steps: steps ?? [], usage: usage)
        }
    }
    private struct AIPatchReply: Decodable { let patch: AIPatch }
    private struct AIAck: Decodable { let ok: Bool? }

    static func aiState(jobID: String) async throws -> AIState {
        try await Api.shared.get("\(base)/jobs/\(jobID)/ai")
    }

    /// Starts a request, hands back the code being sent, then follows the live progress until the model has answered.
    static func aiAsk(jobID: String, message: String, action: String, file: String?, symbol: String?,
                      selection: String?, selectionLine: Int?,
                      onStart: @escaping (AIStarted) -> Void, progress: @escaping (AIProgress) -> Void) async throws -> AIResult {
        var body: [String: Any] = ["message": message, "action": action]
        if let file { body["file"] = file }
        if let symbol { body["symbol"] = symbol }
        if let selection { body["selection"] = selection }
        if let selectionLine { body["selectionLine"] = selectionLine }
        // Starting the job means the server reads the whole project and assembles the prompt before it can even
        // queue the model call — for a large reconstructed dylib that alone can take well past the default 30s.
        let started: AIStarted = try await Api.shared.post("\(base)/jobs/\(jobID)/ai/chat", json: body, timeout: 90)
        await MainActor.run { onStart(started) }
        var misses = 0
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 700_000_000)
            do {
                let j: AIJob = try await Api.shared.get("\(base)/jobs/\(jobID)/ai/jobs/\(started.job)"); misses = 0
                if j.state == "running" { let p = j.progress; await MainActor.run { progress(p) }; continue }
                if j.state == "error" { throw ApiError.server(j.error ?? "The request failed.", 0) }
                if let r = j.result { return r }
                throw ApiError.server("The assistant returned nothing.", 0)
            } catch let e as ApiError where e.status == 0 { throw e }
            catch { misses += 1; if misses > 30 { throw error } }
        }
    }

    static func aiReset(jobID: String) async throws {
        let _: AIAck = try await Api.shared.post("\(base)/jobs/\(jobID)/ai/reset")
    }

    static func aiCancel(jobID: String, job: String) async {
        do { let _: AIAck = try await Api.shared.post("\(base)/jobs/\(jobID)/ai/jobs/\(job)/cancel") } catch {}
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

// MARK: - Formatting helpers

private func fmtMs(_ ms: Int) -> String {
    let s = Double(ms) / 1000
    if s < 10 { return String(format: "%.1fs", s) }
    return fmtSec(Int(s))
}
private func fmtSec(_ s: Int) -> String { s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s" }
func fmtTok(_ n: Int) -> String {
    if n < 1000 { return "\(n)" }
    if n < 100_000 { return String(format: "%.1fk", Double(n) / 1000) }
    return String(format: "%.0fk", Double(n) / 1000)
}

// MARK: - Live processing pieces

/// Four bars that move while the model is working.
struct AIActivityBars: View {
    var active = true
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(Color.dtAccent)
                        .frame(width: 3, height: 5 + 13 * CGFloat(abs(sin(t * 3.2 + Double(i) * 0.9))))
                }
            }
            .frame(height: 18)
        }
    }
}

/// Indeterminate sweep: shows "working", never a fake percentage.
struct AIShimmerLine: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let p = CGFloat(ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [Color.clear, Color.dtAccent, Color.clear], startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * 0.35)
                        .offset(x: g.size.width * 1.35 * p - g.size.width * 0.35)
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 3)
    }
}

struct AIBlinkingCursor: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            Rectangle()
                .fill(Color.dtAccent)
                .frame(width: 7, height: 14)
                .opacity(Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0.15)
        }
    }
}

/// The code that is being sent to the model, shown the moment a request starts.
struct AISnippetCard: View {
    let snippet: ReconstructAPI.AISnippet

    private var title: String {
        switch snippet.kind {
        case "selection": return "Your selection"
        case "symbol": return "Function"
        default: return "Start of file"
        }
    }

    var body: some View {
        let lang = CodeLanguage.detect(snippet.path)
        let count = snippet.text.components(separatedBy: "\n").count
        let nums = (0..<count).map { String(snippet.start + $0) }.joined(separator: "\n")
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "paperplane.fill").font(.caption2)
                Text("Context sent · \(title)").font(.caption2.weight(.semibold))
                Spacer()
                Text("\((snippet.path as NSString).lastPathComponent):\(snippet.start)")
                    .font(.system(size: 10, design: .monospaced)).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.04))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    Text(nums)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.3))
                        .multilineTextAlignment(.trailing)
                    Text(CodeHighlighter.attributed(snippet.text, language: lang))
                }
                .padding(10)
                .fixedSize(horizontal: true, vertical: false)
            }

            if let m = snippet.more, m > 0 {
                Text("+ \(m) more lines in the full context")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
        .background(Color.black.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// What the model is doing right now: timed steps, token speed, and the answer as it is written.
struct AIProgressCard: View {
    let progress: ReconstructAPI.AIProgress
    let started: Date
    let stopping: Bool
    let onStop: () -> Void

    private var title: String {
        if stopping { return "Stopping…" }
        if let a = progress.steps.last(where: { $0.active }) { return a.label }
        return progress.steps.isEmpty ? "Starting…" : "Working…"
    }

    private var modelLine: String? {
        guard let m = progress.model else { return nil }
        return progress.deep ? "\(m) · deep model" : m
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            AIShimmerLine()
            ForEach(Array(progress.steps.enumerated()), id: \.offset) { _, s in stepRow(s) }
            meter
            draft
        }
        .padding(12)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
    }

    private var header: some View {
        HStack(spacing: 10) {
            AIActivityBars(active: !stopping)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                if let ml = modelLine { Text(ml).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            TimelineView(.periodic(from: started, by: 1)) { ctx in
                Text(fmtSec(max(0, Int(ctx.date.timeIntervalSince(started)))))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button(action: onStop) {
                Text(stopping ? "…" : "Stop").font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(stopping)
        }
    }

    private func stepRow(_ s: ReconstructAPI.AIStep) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if s.active {
                    ProgressView().scaleEffect(0.65)
                } else if s.key == "retry" {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Color.orange)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green.opacity(0.85))
                }
            }
            .font(.system(size: 13))
            .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(s.label)
                    .font(.caption.weight(s.active ? .semibold : .regular))
                    .foregroundStyle(s.active ? Color.white : Color.secondary)
                if let d = s.detail, !d.isEmpty {
                    Text(d).font(.caption2).foregroundStyle(.secondary)
                }
                if s.key == "context", !s.active, !progress.sections.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(Array(progress.sections.enumerated()), id: \.offset) { _, name in
                                Text(name).font(.system(size: 10)).lineLimit(1)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Color.white.opacity(0.08), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 4)
            Text(fmtMs(s.ms)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var meter: some View {
        if progress.tokens > 0 {
            HStack(spacing: 12) {
                Label("\(progress.tokens) tokens", systemImage: "number")
                if progress.tps > 0 { Label(String(format: "%.1f tok/s", progress.tps), systemImage: "bolt.fill") }
                if progress.attempt > 1 { Label("attempt \(progress.attempt)", systemImage: "arrow.clockwise") }
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        if progress.stalled {
            Label("No output for a while. The model may be loading or busy.", systemImage: "hourglass")
                .font(.caption2).foregroundStyle(Color.orange)
        }
    }

    @ViewBuilder private var draft: some View {
        if !progress.partial.isEmpty {
            Divider().overlay(Color.white.opacity(0.1))
            VStack(alignment: .leading, spacing: 6) {
                Text("DRAFT").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                MarkdownView(progress.partial)
                AIBlinkingCursor()
            }
        }
    }
}

/// Tokens used in this conversation and how much of the model's context window is still free.
/// (Staff and admin have no caps: the bar is the model's own window, not a quota.)
struct AIUsageBar: View {
    let usage: ReconstructAPI.AIUsage
    /// slim variant that sits inside the composer bar (no background of its own)
    var compact = false
    /// DTX spent in this chat. When set, the bar counts DTX instead of tokens.
    var dtxSpent: Int? = nil
    /// The wallet balance, or nil when signed out.
    var dtxBalance: Int? = nil
    /// Staff and admin are not charged.
    var unmetered = false

    private var usedText: String {
        if let d = dtxSpent { return "\(usage.src == "estimate" ? "≈ " : "")\(d) DTX used" }
        return "\(usage.src == "estimate" ? "≈ " : "")\(fmtTok(usage.used)) used"
    }

    private var leftText: String {
        guard dtxSpent != nil, !unmetered else { return "∞ left" }   // no cap to count down
        guard let b = dtxBalance else { return "Sign in" }
        return "\(compactCount(b)) DTX left"
    }

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            Label { Text(usedText) } icon: {
                if dtxSpent == nil { Image(systemName: "chart.bar.fill") } else { DTXCoin(size: compact ? 14 : 16) }
            }
            Capsule()
                .fill(LinearGradient(colors: [Color.dtAccent.opacity(0.75), Color.dtAccent.opacity(0.25)], startPoint: .leading, endPoint: .trailing))
                .frame(height: compact ? 3 : 4)
            Text(leftText).font(.system(size: compact ? 11 : 12, weight: .semibold))
        }
        .font(.system(size: compact ? 11 : 12).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, compact ? 6 : 8)
        .background(compact ? Color.clear : Color(white: 0.08))
    }
}

// MARK: - Chat sheet

struct ReconAIView: View {
    let jobID: String
    let file: String
    let symbol: String?
    let selection: String?
    let selectionLine: Int?
    /// project files, so names in replies can be made tappable
    let knownFiles: [String]
    /// open a file (and optionally a line) in the editor
    let onOpenFile: (String, Int?) -> Void
    /// called with the paths an applied / reverted patch touched, so the editor can reload them
    let onChanged: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss

    private struct Bubble: Identifiable {
        let id = UUID()
        let role: String                       // user | assistant | context
        var text: String = ""
        var patchID: String? = nil
        var isError = false
        var snippet: ReconstructAPI.AISnippet? = nil
        var meta: String? = nil
        var retry: (text: String, action: String)? = nil
    }

    @State private var bubbles: [Bubble] = []
    @State private var patches: [String: ReconstructAPI.AIPatch] = [:]
    @State private var configured = true
    @State private var input = ""
    @State private var busy = false
    @State private var progress: ReconstructAPI.AIProgress?
    @State private var runJob: String?
    @State private var runStart = Date()
    @State private var stopping = false
    @State private var usage = ReconstructAPI.AIUsage()
    @State private var loadError: String?
    @State private var reviewing: ReconstructAPI.AIPatch?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                contextBar
                transcript
                AIUsageBar(usage: usage)
                inputBar
            }
            .background(Color.black)
            .navigationTitle("Uncrypt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await newConversation() } } label: { Image(systemName: "square.and.pencil") }
                        .disabled(busy || bubbles.isEmpty)
                }
            }
            .sheet(item: $reviewing) { p in
                ReconPatchReview(jobID: jobID, patch: p) { updated, touched in
                    patches[updated.id] = updated
                    if !touched.isEmpty { onChanged(touched) }
                }
            }
            .task { await load() }
            .environment(\.fileRefs, FileRefResolver(files: knownFiles))
            .environment(\.openURL, OpenURLAction { url in
                guard let t = parseFileLink(url) else { return .systemAction }
                onOpenFile(t.path, t.line)
                return .handled
            })
        }
        .preferredColorScheme(.dark)
        .tint(.dtAccent)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let loadError { Text(loadError).font(.caption).foregroundStyle(Color.red) }
                    if !configured {
                        Text("No model is connected on the server yet (OPTIMIZE_LLM_URL). Explanations and patches need one.")
                            .font(.caption).foregroundStyle(Color.orange)
                    }
                    if bubbles.isEmpty && loadError == nil { emptyState }
                    ForEach(bubbles) { b in bubble(b).id(b.id) }
                    if busy {
                        AIProgressCard(progress: progress ?? ReconstructAPI.AIProgress(), started: runStart, stopping: stopping) { stop() }
                            .id("busy")
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(14)
            }
            .onChange(of: bubbles.count) { _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: busy) { b in if b { withAnimation { proxy.scrollTo("end", anchor: .bottom) } } }
            .onChange(of: progress?.partial.count ?? 0) { _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: progress?.steps.count ?? 0) { _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 28)).foregroundStyle(Color.dtAccent)
            Text("Ask about this \(symbol == nil ? "file" : "function")")
                .font(.headline)
            Text("Pick a shortcut or type a request. You'll see the exact code that gets sent, then the model's progress as it works. Changes always arrive as a diff. Nothing is written until you press Apply.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28).padding(.horizontal, 12)
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
            HStack {
                Spacer(minLength: 40)
                Text(b.text).font(.callout).padding(10)
                    .background(Color.dtAccent.opacity(0.22), in: RoundedRectangle(cornerRadius: 14))
                    .textSelection(.enabled)
            }
        } else if b.role == "context", let sn = b.snippet {
            AISnippetCard(snippet: sn)
        } else {
            assistantBubble(b)
        }
    }

    private func assistantBubble(_ b: Bubble) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: b.isError ? "exclamationmark.triangle.fill" : "sparkle").font(.caption2)
                Text(b.isError ? "Problem" : "Uncrypt").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(b.isError ? Color.red : Color.dtAccent)

            if b.isError {
                Text(b.text).font(.callout).foregroundStyle(Color.red).textSelection(.enabled)
            } else {
                MarkdownView(b.text)
            }
            if let pid = b.patchID, let p = patches[pid] { patchCard(p) }
            if let r = b.retry, b.isError {
                Button { retry(b, r) } label: {
                    Label("Try again", systemImage: "arrow.clockwise").font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }.disabled(busy)
            }
            if let m = b.meta {
                Text(m).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(b.isError ? Color.red.opacity(0.08) : Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        .contextMenu {
            Button { UIPasteboard.general.string = b.text } label: { Label("Copy", systemImage: "doc.on.doc") }
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
            if let s = p.summary, !s.isEmpty { Text(MarkdownView.inline(s)).font(.caption).foregroundStyle(.secondary) }
            if let f = p.files, !f.isEmpty {
                Text(f.joined(separator: ", ")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            }
            if p.inference == true {
                Label("Includes the model's own judgement, not only what the evidence shows", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(Color.orange)
            }
            if let ev = p.evidence, !ev.isEmpty {
                ForEach(ev.prefix(4), id: \.self) { e in Text("• " + e).font(.caption2).foregroundStyle(.secondary) }
            }
            if let why = p.blockReason, p.status == "blocked" { Text(why).font(.caption).foregroundStyle(Color.red) }
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
            if let u = st.usage { usage = u }
        } catch {
            loadError = "Couldn't reach the Ai-Decrypt service: \(error.localizedDescription)"
        }
    }

    /// Starts a fresh conversation for this job: clears the chat and the token count. Patches stay (and the model still sees them).
    private func newConversation() async {
        do {
            try await ReconstructAPI.aiReset(jobID: jobID)
            bubbles = []
            usage = ReconstructAPI.AIUsage(prompt: 0, completion: 0, lastPrompt: 0, ctx: usage.ctx, src: nil)
        } catch { loadError = "Couldn't start a new conversation: \(error.localizedDescription)" }
    }

    private func openReview(_ p: ReconstructAPI.AIPatch) async {
        if p.changes != nil { reviewing = p; return }
        if let full = try? await ReconstructAPI.aiPatch(jobID: jobID, id: p.id) { patches[p.id] = full; reviewing = full }
    }

    private func stop() {
        guard let j = runJob, !stopping else { return }
        stopping = true
        Task { await ReconstructAPI.aiCancel(jobID: jobID, job: j) }
    }

    private func retry(_ b: Bubble, _ r: (text: String, action: String)) {
        guard !busy, let idx = bubbles.firstIndex(where: { $0.id == b.id }) else { return }
        bubbles.remove(at: idx)
        if idx > 0, bubbles[idx - 1].role == "user" { bubbles.remove(at: idx - 1) }
        send(r.text, action: r.action)
    }

    private func metaLine() -> String? {
        let secs = Int(Date().timeIntervalSince(runStart))
        var parts = [fmtSec(secs)]
        if let p = progress {
            if p.tokens > 0 { parts.append("\(p.tokens) tokens") }
            if p.tps > 0 { parts.append(String(format: "%.1f tok/s", p.tps)) }
            if p.attempt > 1 { parts.append("attempt \(p.attempt)") }
        }
        return parts.joined(separator: " · ")
    }

    private func send(_ text: String, action: String) {
        guard !busy else { return }
        bubbles.append(Bubble(role: "user", text: text))
        busy = true; progress = nil; runJob = nil; stopping = false; runStart = Date(); focused = false
        Task {
            do {
                let r = try await ReconstructAPI.aiAsk(
                    jobID: jobID, message: text, action: action, file: file, symbol: symbol,
                    selection: selection, selectionLine: selectionLine,
                    onStart: { st in
                        runJob = st.job
                        if let sn = st.snippet { bubbles.append(Bubble(role: "context", snippet: sn)) }
                        if let u = st.usage {
                            var v = u
                            v.ctx = (st.ctx ?? 0) > 0 ? st.ctx : usage.ctx
                            usage = v
                        }
                    },
                    progress: { p in
                        progress = p
                        if var u = p.usage {
                            if (u.ctx ?? 0) == 0 { u.ctx = usage.ctx }
                            usage = u
                        }
                    })
                var b = Bubble(role: "assistant", text: r.reply)
                b.meta = metaLine()
                if let p = r.patch { patches[p.id] = p; b.patchID = p.id }
                bubbles.append(b)
            } catch {
                var b = Bubble(role: "assistant", text: error.localizedDescription, isError: true)
                b.retry = (text: text, action: action)
                bubbles.append(b)
            }
            busy = false; progress = nil; runJob = nil; stopping = false
            if let st = try? await ReconstructAPI.aiState(jobID: jobID), let u = st.usage { usage = u }
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
