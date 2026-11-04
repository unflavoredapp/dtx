import SwiftUI

// MARK: - Project-wide code intelligence: symbol search + "find references"

/// Backed by symbols.js: a regex index over every source file in the project (classes, methods, bare functions,
/// macros, constructors), rebuilt fresh on each request. Works for both reconstructed and AI-authored projects.
extension ReconstructAPI {
    struct Symbol: Decodable, Identifiable, Equatable {
        var id: String { "\(file):\(line):\(name)" }
        var name: String; var kind: String; var file: String; var line: Int; var signature: String?
        /// "ast" when clang's real AST resolved this (accurate), "regex" when it fell back to a text scan
        /// (SDK unavailable or the file doesn't parse standalone) — shown as a subtle dot, not a disclaimer.
        var source: String?
    }
    struct Reference: Decodable, Identifiable {
        var id: String { "\(file):\(line)" }
        var file: String; var line: Int; var text: String
    }
    private struct SymbolsReply: Decodable { var symbols: [Symbol] }
    private struct RefsReply: Decodable { var symbol: String; var refs: [Reference] }

    private static func urlEnc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }

    static func symbols(jobID: String, query: String = "") async throws -> [Symbol] {
        let q = query.isEmpty ? "" : "?q=\(urlEnc(query))"
        let r: SymbolsReply = try await Api.shared.get("\(base)/jobs/\(jobID)/symbols\(q)")
        return r.symbols
    }
    static func references(jobID: String, symbol: String) async throws -> [Reference] {
        let r: RefsReply = try await Api.shared.get("\(base)/jobs/\(jobID)/references?symbol=\(urlEnc(symbol))")
        return r.refs
    }
}

/// A full-project symbol list with live filtering, and "find references" per symbol — the cross-file awareness
/// the per-file editor's jump(toSymbol:) doesn't have on its own. Opened from the editor's toolbar.
struct AiSymbolSearchSheet: View {
    let jobID: String
    let onOpen: (String, Int) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var all: [ReconstructAPI.Symbol] = []
    @State private var loading = true
    @State private var error: String?
    @State private var refsFor: ReconstructAPI.Symbol?

    private var filtered: [ReconstructAPI.Symbol] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        let q = query.lowercased()
        return all.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Indexing…")
                } else if let error {
                    Text(error).font(.callout).foregroundStyle(.red).padding()
                } else if filtered.isEmpty {
                    Text(all.isEmpty ? "No symbols found." : "No match for \"\(query)\".").font(.footnote).foregroundStyle(.secondary).padding()
                } else {
                    List(filtered) { s in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: icon(for: s.kind)).font(.caption).foregroundStyle(Color.dtAccent).frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(.system(size: 13, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Text("\(s.file):\(s.line)").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if s.source == "regex" {
                                Circle().fill(Color.secondary.opacity(0.4)).frame(width: 5, height: 5)
                                    .help("Found by text scan, not a full parse")
                            }
                            Button { refsFor = s } label: {
                                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                            }.buttonStyle(.plain)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { onOpen(s.file, s.line); dismiss() }
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $query, prompt: "Classes, methods, functions…")
            .navigationTitle("Symbols")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } } }
            .sheet(item: $refsFor) { s in
                AiReferencesSheet(jobID: jobID, symbol: s) { file, line in onOpen(file, line); dismiss() }
            }
            .task { await load() }
            .preferredColorScheme(.dark)
            .tint(.dtAccent)
        }
    }

    private func load() async {
        loading = true; error = nil
        do { all = try await ReconstructAPI.symbols(jobID: jobID).sorted { $0.name.lowercased() < $1.name.lowercased() } }
        catch { self.error = "Couldn't load the symbol index: \(error.localizedDescription)" }
        loading = false
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "class", "category": return "cube"
        case "method": return "curlybraces"
        case "function": return "function"
        case "macro": return "number"
        case "constructor": return "bolt"
        default: return "doc"
        }
    }
}

/// Every line that mentions a symbol, across every source file — "find references" without an AST.
struct AiReferencesSheet: View {
    let jobID: String
    let symbol: ReconstructAPI.Symbol
    let onOpen: (String, Int) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var refs: [ReconstructAPI.Reference] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading { ProgressView("Searching…") }
                else if let error { Text(error).font(.callout).foregroundStyle(.red).padding() }
                else if refs.isEmpty { Text("No other references found.").font(.footnote).foregroundStyle(.secondary).padding() }
                else {
                    List(refs) { r in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.text).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                            Text("\(r.file):\(r.line)").font(.caption2).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { onOpen(r.file, r.line); dismiss() }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(symbol.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } } }
            .task { await load() }
            .preferredColorScheme(.dark)
            .tint(.dtAccent)
        }
    }

    private func load() async {
        loading = true; error = nil
        do { refs = try await ReconstructAPI.references(jobID: jobID, symbol: symbol.name) }
        catch { self.error = "Couldn't search for references: \(error.localizedDescription)" }
        loading = false
    }
}
