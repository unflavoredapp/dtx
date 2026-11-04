import SwiftUI

// MARK: - propose_dylib_plan: a planning step before any code is written

/// For a new dylib that isn't already fully specified, the model proposes a plan first (no files, nothing
/// server-side happens): the classes/files it intends to write, which frameworks, how it hooks in, and the
/// risks. The person approves or asks for changes; only on approval does a second turn ask the model to call
/// create_dylib. This is a real gate — create_dylib is never called by the model in the same turn as the plan.
enum AiDylibPlanTool {
    static let name = "propose_dylib_plan"

    static let schema: [String: Any] = [
        "type": "function",
        "function": [
            "name": name,
            "description": "For a NEW dylib request that isn't already fully specified (vague goal, or anything more than a one-file hook), propose a PLAN before writing any code: what it does, the files you intend to write and why, frameworks, how it hooks into the app, and the real risks. Writes nothing. Call this BEFORE create_dylib unless the person has already given exact files/behaviour and said to just write it. The person approves or asks for changes from the card; wait for that before calling create_dylib.",
            "parameters": [
                "type": "object",
                "properties": [
                    "goal": ["type": "string", "description": "One or two sentences: what this dylib does and why."],
                    "frameworks": ["type": "array", "items": ["type": "string"]],
                    "hookApproach": ["type": "string", "description": "How it hooks into the app at runtime, in plain words."],
                    "files": ["type": "array", "items": [
                        "type": "object",
                        "properties": ["path": ["type": "string"], "purpose": ["type": "string"]],
                        "required": ["path", "purpose"],
                    ] as [String: Any]],
                    "risks": ["type": "array", "items": ["type": "string"], "description": "Real risks or things that could go wrong (crashes, App Store detection if relevant, side effects on other app behaviour)."],
                ],
                "required": ["goal", "files"],
            ] as [String: Any],
        ] as [String: Any],
    ]

    struct FileStub: Equatable { var path: String; var purpose: String }
    struct Plan: Equatable {
        var goal: String
        var frameworks: [String]
        var hookApproach: String
        var files: [FileStub]
        var risks: [String]
    }

    static func parse(_ arguments: String) -> Plan? {
        guard let d = arguments.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let goal = (o["goal"] as? String) ?? ""
        guard !goal.isEmpty else { return nil }
        let files = ((o["files"] as? [[String: Any]]) ?? []).map { FileStub(path: ($0["path"] as? String) ?? "", purpose: ($0["purpose"] as? String) ?? "") }
        return Plan(goal: goal, frameworks: (o["frameworks"] as? [String]) ?? [], hookApproach: (o["hookApproach"] as? String) ?? "",
                    files: files, risks: (o["risks"] as? [String]) ?? [])
    }
}

extension AiDecryptViewModel {
    func proposeDylibPlan(arguments: String, into index: Int) -> String {
        guard let plan = AiDylibPlanTool.parse(arguments) else {
            return "The plan arguments were not valid (need at least goal and files). Try again."
        }
        guard index < messages.count else { return "Cancelled." }
        if messages[index].content.hasPrefix("Running ") { messages[index].content = "" }
        messages[index].card = .dylibPlan(plan)
        messages[index].toolCalls = nil
        return "A plan is on screen (goal, \(plan.files.count) file(s), hook approach, \(plan.risks.count) risk(s)). NOTHING is written. Say in one or two lines what it does; don't repeat the full plan — the card shows it. Wait for the person to approve or ask for changes before calling create_dylib."
    }
}

// MARK: - Plan card

struct AiDylibPlanCard: View {
    let plan: AiDylibPlanTool.Plan
    @State private var decided = false
    @State private var changesText = ""
    @State private var showChanges = false

    var body: some View {
        if decided {
            Label("Plan approved — ask for the files above.", systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary).padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.clipboard").foregroundStyle(Color.dtAccent)
                    Text("Plan").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Spacer(minLength: 0)
                    Text("NOTHING WRITTEN YET").font(.caption2.bold()).foregroundStyle(.secondary)
                }
                Text(plan.goal).font(.footnote).foregroundStyle(.white.opacity(0.9))
                if !plan.hookApproach.isEmpty {
                    row(icon: "link", title: "How it hooks in", text: plan.hookApproach)
                }
                if !plan.frameworks.isEmpty {
                    row(icon: "shippingbox", title: "Frameworks", text: plan.frameworks.joined(separator: ", "))
                }
                if !plan.files.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Files", systemImage: "folder").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(plan.files, id: \.path) { f in
                            HStack(alignment: .top, spacing: 6) {
                                Text("src/" + f.path).font(.caption.monospaced()).foregroundStyle(Color.dtAccent)
                                Text("— " + f.purpose).font(.caption).foregroundStyle(.white.opacity(0.85))
                            }
                        }
                    }
                }
                if !plan.risks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Risks", systemImage: "exclamationmark.triangle").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        ForEach(plan.risks, id: \.self) { Text("• " + $0).font(.caption).foregroundStyle(.white.opacity(0.85)) }
                    }
                }
                if showChanges {
                    TextField("What should change about the plan?", text: $changesText, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...4)
                }
                HStack(spacing: 8) {
                    Button {
                        decided = true
                        NotificationCenter.default.post(name: .liveAskAI, object: "Approved. Write the files for this plan now with create_dylib.")
                    } label: {
                        Label("Approve — write it", systemImage: "checkmark").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.dtOnAccent).padding(.horizontal, 16).padding(.vertical, 9).background(Capsule().fill(Color.dtAccent))
                    }
                    if showChanges {
                        Button {
                            let t = changesText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            decided = true
                            NotificationCenter.default.post(name: .liveAskAI, object: "Change the plan: \(t)")
                        } label: {
                            Text("Send").font(.system(size: 15, weight: .medium)).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 9).aiGlass(Capsule())
                        }
                    } else {
                        Button { showChanges = true } label: {
                            Text("Needs changes").font(.system(size: 15, weight: .medium)).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 9).aiGlass(Capsule())
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder private func row(icon: String, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.white.opacity(0.85))
        }
    }
}
