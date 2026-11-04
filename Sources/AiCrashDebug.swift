import SwiftUI

// MARK: - debug_crash: paste a crash log, get the function/file/line it hit, then let the AI propose a fix

/// Server-side locate/check-crash already exist for every project (reconstructed or authored) since both are
/// registered as ordinary jobs/parts. This just wires them into the chat: the model passes through whatever crash
/// text the person pasted, the server maps each frame to a recovered function (when the project has an address
/// table) and says whether the crash is from the dylib currently built here or a stale one, and the card offers
/// "Ask AI to fix" on the frame that actually crashed.
enum AiCrashTool {
    static let name = "debug_crash"

    static let schema: [String: Any] = [
        "type": "function",
        "function": [
            "name": name,
            "description": "The person pasted a crash log, a .ips file, or described a crash with an address/offset/stack line for the project open in this chat. Pass the crash text through EXACTLY as pasted (the full .ips if that's what they gave). Maps each frame in THIS dylib to the recovered function/file it lands in, and says whether this crash matches the dylib as last built here or is stale (from before the last fix). Shows its own card; don't explain the mapping yourself, just say in one line what crashed and whether it's fresh.",
            "parameters": [
                "type": "object",
                "properties": ["report": ["type": "string", "description": "The crash text exactly as pasted — a full .ips file, a symbolicated stack line, or a bare address."]],
                "required": ["report"],
            ] as [String: Any],
        ] as [String: Any],
    ]

    struct Match: Decodable, Identifiable {
        var id: String { hex + (function ?? "") }
        var offset: Int
        var hex: String
        var thread: Int?
        var triggered: Bool?
        var symbol: String?
        var function: String?
        var kind: String?
        var file: String?
        var confidence: String?
        var risky: Bool?
    }
    private struct LocateReply: Decodable { var matched: Bool; var image: String?; var imageMatchKind: String?; var candidateImages: [String]?; var matches: [Match]? }
    struct CheckCrash: Decodable { var verdict: String; var duplicate: Bool?; var crashUuid: String?; var builtUuid: String?; var incidentId: String?; var captureTime: String? }

    struct Result {
        var image: String?
        var matches: [Match]
        var check: CheckCrash?
        var noAddressTable: Bool   // an authored project has no decompiled function table to map offsets against
    }

    static func run(jobID: String, report: String) async throws -> Result {
        let base = ReconstructAPI.base
        let locData = try await Api.shared.upload("POST", "\(base)/jobs/\(jobID)/locate", body: Data(report.utf8))
        let loc = try JSONDecoder().decode(LocateReply.self, from: locData)
        var check: CheckCrash?
        if loc.matched {
            let chkData = try await Api.shared.upload("POST", "\(base)/jobs/\(jobID)/check-crash", body: Data(report.utf8))
            check = try? JSONDecoder().decode(CheckCrash.self, from: chkData)
        }
        let matches = loc.matches ?? []
        let noAddressTable = loc.matched && !matches.isEmpty && matches.allSatisfy { $0.function == nil }
        return Result(image: loc.image, matches: matches, check: check, noAddressTable: noAddressTable)
    }
}

extension AiDecryptViewModel {
    func proposeCrashDebug(arguments: String, into index: Int) async -> String {
        guard let d = arguments.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let report = (o["report"] as? String), !report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "No crash text was given. Ask the person to paste the crash log or .ips file."
        }
        guard let project = latestReconProject else {
            return "There is no project open in this chat to map the crash against."
        }
        do {
            let r = try await AiCrashTool.run(jobID: project.jobID, report: report)
            guard index < messages.count else { return "Cancelled." }
            if messages[index].content.hasPrefix("Running ") { messages[index].content = "" }
            messages[index].card = .crash(project.jobID, project.name, r.matches, r.check)
            messages[index].toolCalls = nil
            if r.matches.isEmpty {
                return "No frame in the pasted text matched \(project.name) — tell the person this crash doesn't look like it's from this dylib (check for \(project.name) in the pasted text), unless they can paste the full .ips."
            }
            if r.noAddressTable {
                return "The crash maps to offsets in \(project.name), but this project has no decompiled address table (it's an AI-authored dylib, not reconstructed from a binary), so the exact function can't be named automatically. The card shows the raw offsets; ask the person which function they suspect, or for the symbolicated frame names, then call edit_code with that."
            }
            let top = r.matches.first(where: { $0.triggered == true }) ?? r.matches.first
            let fresh = r.check?.verdict == "fresh" ? "This matches the dylib as currently built here." :
                        r.check?.verdict == "stale" ? "This is a STALE crash — it's from an older build, before the last fix; tell the person to confirm on a fresh build before trusting it." :
                        r.check?.verdict == "unverified-no-build-yet" ? "This project hasn't been built here yet, so freshness can't be checked." : ""
            let where_ = top?.function.map { "\($0)" + (top?.file.map { " in \($0)" } ?? "") } ?? "an unmapped address"
            return "The crashing frame maps to \(where_)\(top?.risky == true ? " (flagged risky by the correctness gate)" : ""). \(fresh) The card has \"Ask AI to fix\" on it — say in one line what crashed and ask if they want the fix proposed, don't repeat the full table."
        } catch {
            return "Couldn't map that crash: \(error.localizedDescription)"
        }
    }
}

// MARK: - Crash card

struct AiCrashCard: View {
    let jobID: String
    let name: String
    let matches: [AiCrashTool.Match]
    let check: AiCrashTool.CheckCrash?

    @State private var fixing: String?       // offset hex currently being fixed
    @State private var fixPatchID: String?
    @State private var fixReply = ""
    @State private var error: String?

    private var topIndex: Int? {
        matches.firstIndex(where: { $0.triggered == true }) ?? (matches.isEmpty ? nil : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.trianglebadge.exclamationmark.fill").foregroundStyle(.red)
                Text("Crash in \(name)").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Spacer(minLength: 0)
                if let v = check?.verdict { verdictBadge(v) }
            }
            if matches.isEmpty {
                Text("No frame in the pasted text matched this dylib.").font(.footnote).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(matches.prefix(12).enumerated()), id: \.offset) { i, m in
                        HStack(alignment: .top, spacing: 8) {
                            Text(m.triggered == true ? "⚡︎" : " ").font(.caption)
                            VStack(alignment: .leading, spacing: 2) {
                                Text((m.function ?? m.symbol ?? m.hex)).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.white)
                                HStack(spacing: 6) {
                                    if let f = m.file { Text(f).font(.caption2).foregroundStyle(.secondary) }
                                    if m.risky == true { Text("risky").font(.caption2.bold()).foregroundStyle(.orange) }
                                    if m.confidence == "nearest" { Text("approx.").font(.caption2).foregroundStyle(.secondary) }
                                }
                            }
                            Spacer(minLength: 0)
                            if i == topIndex, m.function != nil {
                                Button {
                                    Task { await fix(m) }
                                } label: {
                                    if fixing == m.hex { ProgressView().scaleEffect(0.6) }
                                    else { Text("Ask AI to fix").font(.caption.weight(.semibold)).foregroundStyle(Color.dtAccent) }
                                }.disabled(fixing != nil)
                            }
                        }
                    }
                    if matches.count > 12 { Text("+\(matches.count - 12) more frame(s)").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            if let e = error { Text(e).font(.caption).foregroundStyle(.red) }
            if let f = fixPatchID {
                if !fixReply.isEmpty { Text(fixReply).font(.footnote).foregroundStyle(.white.opacity(0.85)) }
                AiPatchCard(jobID: jobID, patchID: f, name: name, depth: 1, autoBuild: false).id(f)
            }
        }
        .padding(12)
    }

    @ViewBuilder private func verdictBadge(_ v: String) -> some View {
        let (text, color): (String, Color) = {
            switch v {
            case "fresh": return ("current build", .green)
            case "stale": return ("stale crash", .orange)
            case "unverified-no-build-yet": return ("not built here yet", .secondary)
            default: return ("unverified", .secondary)
            }
        }()
        Text(text).font(.caption2.bold()).padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.22))).foregroundStyle(color)
    }

    private func fix(_ m: AiCrashTool.Match) async {
        fixing = m.hex; error = nil; defer { fixing = nil }
        let ask = "The app crashed at \(m.function ?? m.hex)\(m.file.map { " in \($0)" } ?? "")\(m.risky == true ? " — this was already flagged as a risky initializer by the correctness gate" : ""). " +
                  "Find the real cause and propose a minimal, correct fix that keeps the original behaviour: do not delete the function, stub it out, or swallow the crash with a try/catch that hides the bug. Explain the likely cause in the reply."
        do {
            let r = try await ReconstructAPI.aiAsk(jobID: jobID, message: ask, action: "fix", file: m.file, symbol: m.function, selection: nil, selectionLine: nil,
                                                  onStart: { _ in }, progress: { _ in })
            fixReply = r.reply
            if let p = r.patch { fixPatchID = p.id } else { error = "No safe fix was found: " + r.reply }
        } catch { self.error = error.localizedDescription }
    }
}
