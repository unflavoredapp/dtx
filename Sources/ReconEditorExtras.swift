import SwiftUI
import UIKit

// MARK: - API (diff baseline, changed files, per-function evidence, build diagnostics)

extension ReconstructAPI {
    private static func encPath(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }

    struct OriginalReply: Decodable { let baseline: Bool; let text: String? }
    struct ChangeEntry: Decodable { let path: String; let changed: Bool }
    private struct ChangesReply: Decodable { let files: [ChangeEntry] }

    struct Evidence: Decodable, Hashable { let ok: Bool; let text: String; let detail: String? }
    struct FuncRecord: Decodable, Identifiable {
        var id: String { label + (addr ?? "") }
        let label: String
        let addr: String?
        let file: String?
        let score: Int
        let level: String
        let capped: Bool?
        let evidence: [Evidence]
    }
    struct GateFinding: Decodable { let id: String?; let message: String? }
    struct Gate: Decodable { let status: String?; let errors: Int?; let warnings: Int?; let top: [GateFinding]? }
    struct Records: Decodable {
        let avg: Int?
        let total: Int
        let functions: [FuncRecord]
        let gate: Gate?
    }

    struct DiagItem: Decodable, Hashable { let line: Int; let col: Int; let sev: String; let msg: String }
    struct Diagnostics: Decodable {
        let buildState: String?
        let files: [String: [DiagItem]]
        let failed: [String]?
        let errors: Int?
        let hasReport: Bool?

        func items(for path: String) -> [DiagItem] {
            if let a = files[path] { return a }
            for (k, v) in files where !k.isEmpty && (k.hasSuffix(path) || path.hasSuffix(k)) { return v }
            return []
        }
        func errorCount(for path: String) -> Int { items(for: path).filter { $0.sev == "error" }.count }
    }

    static func original(jobID: String, path: String) async throws -> String? {
        let r: OriginalReply = try await Api.shared.get("\(base)/jobs/\(jobID)/original?path=\(encPath(path))")
        return r.baseline ? r.text : nil
    }
    static func changes(jobID: String) async throws -> [ChangeEntry] {
        let r: ChangesReply = try await Api.shared.get("\(base)/jobs/\(jobID)/changes")
        return r.files
    }
    static func records(jobID: String) async throws -> Records {
        try await Api.shared.get("\(base)/jobs/\(jobID)/records")
    }
    static func diagnostics(jobID: String) async throws -> Diagnostics {
        try await Api.shared.get("\(base)/jobs/\(jobID)/diagnostics")
    }
}

// MARK: - Line diff

struct DiffHunk: Identifiable {
    let id = UUID()
    var oldStart: Int
    var oldLines: [String]
    var newStart: Int
    var newLines: [String]
}

enum LineDiff {
    static func lines(_ s: String) -> [String] { s.components(separatedBy: "\n") }

    static func hunks(old: [String], new: [String]) -> [DiffHunk] {
        var p = 0
        while p < old.count && p < new.count && old[p] == new[p] { p += 1 }
        var oe = old.count, ne = new.count
        while oe > p && ne > p && old[oe - 1] == new[ne - 1] { oe -= 1; ne -= 1 }
        let a = Array(old[p..<oe]), b = Array(new[p..<ne])
        if a.isEmpty && b.isEmpty { return [] }
        if a.isEmpty || b.isEmpty || a.count * b.count > 4_000_000 {
            return [DiffHunk(oldStart: p, oldLines: a, newStart: p, newLines: b)]
        }
        let n = a.count, m = b.count, w = m + 1
        var dp = [Int32](repeating: 0, count: (n + 1) * w)
        var i = n - 1
        while i >= 0 {
            var j = m - 1
            while j >= 0 {
                dp[i * w + j] = a[i] == b[j] ? dp[(i + 1) * w + j + 1] + 1 : max(dp[(i + 1) * w + j], dp[i * w + j + 1])
                j -= 1
            }
            i -= 1
        }
        var out: [DiffHunk] = []
        var cur: DiffHunk?
        func flush() { if let c = cur { out.append(c); cur = nil } }
        i = 0
        var j = 0
        while i < n || j < m {
            if i < n && j < m && a[i] == b[j] {
                flush(); i += 1; j += 1
            } else if j < m && (i == n || dp[i * w + j + 1] >= dp[(i + 1) * w + j]) {
                if cur == nil { cur = DiffHunk(oldStart: p + i, oldLines: [], newStart: p + j, newLines: []) }
                cur?.newLines.append(b[j]); j += 1
            } else {
                if cur == nil { cur = DiffHunk(oldStart: p + i, oldLines: [], newStart: p + j, newLines: []) }
                cur?.oldLines.append(a[i]); i += 1
            }
        }
        flush()
        return out
    }
}

// MARK: - Diff sheet (current editor text vs what the engine generated)

struct ReconDiffView: View {
    let path: String
    let baseline: String
    let ctl: CodeEditorController
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var newLines: [String] = []
    @State private var hunks: [DiffHunk] = []

    var body: some View {
        NavigationStack {
            Group {
                if hunks.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(Color.dtAccent)
                        Text("Identical to the generated version").font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(hunks) { h in
                            Section {
                                ForEach(Array(context(before: h).enumerated()), id: \.offset) { _, l in row(l, " ", .secondary) }
                                ForEach(Array(h.oldLines.enumerated()), id: \.offset) { _, l in row(l, "−", .red) }
                                ForEach(Array(h.newLines.enumerated()), id: \.offset) { _, l in row(l, "+", .green) }
                                ForEach(Array(context(after: h).enumerated()), id: \.offset) { _, l in row(l, " ", .secondary) }
                            } header: {
                                HStack {
                                    Text("Line \(h.newStart + 1) · −\(h.oldLines.count) +\(h.newLines.count)").font(.caption.monospaced())
                                    Spacer()
                                    Button("Revert") { revert(h) }.font(.caption.bold())
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Diff · " + (path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Revert all") { revertAll() }.disabled(hunks.isEmpty)
                }
            }
            .onAppear { recompute() }
        }
        .preferredColorScheme(.dark)
        .tint(.dtAccent)
    }

    private func row(_ text: String, _ mark: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(mark).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(color).frame(width: 10)
            Text(text.isEmpty ? " " : text).font(.system(size: 12, design: .monospaced)).foregroundStyle(color == .secondary ? Color.secondary : color)
        }
        .listRowBackground(color == .red ? Color.red.opacity(0.10) : color == .green ? Color.green.opacity(0.10) : Color.clear)
        .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
    }

    private func context(before h: DiffHunk) -> [String] {
        let s = max(0, h.newStart - 2)
        return s < h.newStart && h.newStart <= newLines.count ? Array(newLines[s..<h.newStart]) : []
    }
    private func context(after h: DiffHunk) -> [String] {
        let e = h.newStart + h.newLines.count
        return e < newLines.count ? Array(newLines[e..<min(newLines.count, e + 2)]) : []
    }

    private func recompute() {
        newLines = LineDiff.lines(ctl.text())
        hunks = LineDiff.hunks(old: LineDiff.lines(baseline), new: newLines)
    }

    private func revert(_ h: DiffHunk) {
        var lines = newLines
        let end = min(lines.count, h.newStart + h.newLines.count)
        guard h.newStart <= end else { return }
        lines.replaceSubrange(h.newStart..<end, with: h.oldLines)
        ctl.replaceAllText(lines.joined(separator: "\n"))
        onChanged()
        recompute()
    }

    private func revertAll() {
        ctl.replaceAllText(baseline)
        onChanged()
        recompute()
    }
}

// MARK: - Problems sheet (build diagnostics)

struct ReconProblemsView: View {
    let path: String
    let diag: ReconstructAPI.Diagnostics?
    let onOpen: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let d = diag, d.hasReport == true || !d.files.isEmpty {
                    let mine = d.items(for: path)
                    List {
                        Section("This file") {
                            if mine.isEmpty { Text("No problems in this file.").foregroundStyle(.secondary).font(.callout) }
                            ForEach(mine, id: \.self) { it in
                                Button { dismiss(); onOpen(it.line) } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: it.sev == "error" ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                            .foregroundStyle(it.sev == "error" ? Color.red : Color.yellow)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(it.msg).font(.system(size: 13)).foregroundStyle(.white).multilineTextAlignment(.leading)
                                            Text("line \(it.line):\(it.col)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        let others = d.files.keys.sorted().filter { k in k != path && !path.hasSuffix(k) && !k.hasSuffix(path) }
                        if !others.isEmpty {
                            Section("Other files") {
                                ForEach(others, id: \.self) { k in
                                    HStack {
                                        Text(k).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text("\(d.files[k]?.filter { $0.sev == "error" }.count ?? 0) err").font(.caption2).foregroundStyle(.red)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "hammer").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Build the dylib to see problems here.").font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Problems")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .tint(.dtAccent)
    }
}

// MARK: - Evidence sheet (per-function confidence)

struct ReconEvidenceView: View {
    let jobID: String
    let fileFilter: String?
    let onOpen: (ReconstructAPI.FuncRecord) -> Void
    var onAsk: ((ReconstructAPI.FuncRecord) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var recs: ReconstructAPI.Records?
    @State private var error: String?
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var onlyThisFile = true

    private var shown: [ReconstructAPI.FuncRecord] {
        guard let r = recs else { return [] }
        var list = r.functions
        if let f = fileFilter, onlyThisFile {
            let mine = list.filter { $0.file == f }
            if !mine.isEmpty { list = mine }
        }
        if !query.isEmpty { list = list.filter { $0.label.localizedCaseInsensitiveContains(query) } }
        return list
    }

    var body: some View {
        NavigationStack {
            Group {
                if let error {
                    VStack(spacing: 10) {
                        Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                        Button("Retry") { Task { await load() } }
                    }.padding()
                } else if recs == nil {
                    ProgressView("Loading evidence…")
                } else if let r = recs {
                    List {
                        Section {
                            HStack {
                                stat("Avg", r.avg.map(String.init) ?? "–")
                                stat("Functions", String(r.total))
                                if let g = r.gate, let s = g.status { stat("Gate", s) }
                            }
                            if let g = r.gate, let top = g.top, !top.isEmpty {
                                ForEach(Array(top.enumerated()), id: \.offset) { _, f in
                                    Text(f.message ?? f.id ?? "").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            if fileFilter != nil {
                                Toggle("Only this file", isOn: $onlyThisFile).font(.callout)
                            }
                        }
                        Section("Lowest confidence first") {
                            ForEach(shown) { f in
                                VStack(alignment: .leading, spacing: 6) {
                                    Button {
                                        if expanded.contains(f.id) { expanded.remove(f.id) } else { expanded.insert(f.id) }
                                    } label: {
                                        HStack(spacing: 8) {
                                            Text("\(f.score)").font(.system(size: 12, weight: .bold, design: .monospaced))
                                                .frame(width: 34).padding(.vertical, 2)
                                                .background(color(f.level).opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
                                                .foregroundStyle(color(f.level))
                                            Text(f.label).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white)
                                                .lineLimit(2).multilineTextAlignment(.leading)
                                            Spacer(minLength: 0)
                                            Image(systemName: expanded.contains(f.id) ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    if expanded.contains(f.id) {
                                        ForEach(f.evidence, id: \.self) { e in
                                            HStack(alignment: .top, spacing: 6) {
                                                Image(systemName: e.ok ? "checkmark.circle.fill" : "minus.circle").font(.caption)
                                                    .foregroundStyle(e.ok ? Color.green : Color.orange)
                                                VStack(alignment: .leading, spacing: 1) {
                                                    Text(e.text).font(.caption)
                                                    if let d = e.detail, !d.isEmpty { Text(d).font(.caption2).foregroundStyle(.secondary) }
                                                }
                                            }
                                        }
                                        if let ask = onAsk {
                                            Button { ask(f) } label: { Label("Ask Ai-Decrypt about this", systemImage: "sparkles") }
                                                .font(.caption.bold())
                                        }
                                        if f.file != nil {
                                            Button { dismiss(); onOpen(f) } label: { Label("Open in editor", systemImage: "arrow.right.circle") }
                                                .font(.caption.bold())
                                        } else if fileFilter != nil {
                                            Button { dismiss(); onOpen(f) } label: { Label("Jump to function", systemImage: "arrow.right.circle") }
                                                .font(.caption.bold())
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: $query, prompt: "Filter functions")
                }
            }
            .navigationTitle("Function evidence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
        .preferredColorScheme(.dark)
        .tint(.dtAccent)
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.system(size: 17, weight: .bold, design: .monospaced))
            Text(k).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "high": return .green
        case "medium": return .yellow
        case "low": return .orange
        default: return .red
        }
    }

    private func load() async {
        error = nil
        do { recs = try await ReconstructAPI.records(jobID: jobID) }
        catch { self.error = "Couldn't load evidence: \(error.localizedDescription)" }
    }
}
