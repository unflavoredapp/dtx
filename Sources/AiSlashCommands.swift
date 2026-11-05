import SwiftUI

// MARK: - /help and /info — handled entirely in the app, no model round-trip, no tokens spent

extension AiDecryptViewModel {
    /// Returns true if `text` was a recognized slash command and has already been fully handled (message
    /// appended, draft cleared, persisted). `send()` checks this before anything else — a slash command never
    /// reaches the model.
    func handleSlashCommand(_ text: String) -> Bool {
        guard text.hasPrefix("/") else { return false }
        let name = text.dropFirst().split(separator: " ", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
        switch name {
        case "help", "commands", "?":
            messages.append(AiChatMessage(role: .user, content: text))
            messages.append(AiChatMessage(role: .assistant, content: AiSlashCommands.helpText(
                hasStaffTools: AiDylibTool.available, hasProject: latestReconProject != nil, hasLiveTools: AiLiveRelease.available)))
            draft = ""; errorText = nil; persist()
            return true
        case "info", "about", "version":
            messages.append(AiChatMessage(role: .user, content: text))
            let idx = messages.count
            messages.append(AiChatMessage(role: .assistant, content: "Checking the server…"))
            draft = ""; errorText = nil; persist()
            Task { [weak self] in
                let result = await AiSlashCommands.infoText()
                await MainActor.run {
                    guard let self, idx < self.messages.count else { return }
                    self.messages[idx].content = result
                    self.persist()
                }
            }
            return true
        default:
            return false
        }
    }
}

enum AiSlashCommands {
    static func helpText(hasStaffTools: Bool, hasProject: Bool, hasLiveTools: Bool) -> String {
        var lines = [
            "**Commands**",
            "`/help` — this list",
            "`/info` — app version, server and AI model",
            "",
            "**Just ask, in plain words:**",
            "• Find or decrypt an app, or list what's in your library",
            "• Explain, fix, or improve code in a project you've opened here",
            "• Paste a crash log or a full `.ips` file — it maps straight to the function that crashed and offers a fix",
        ]
        if hasStaffTools {
            lines += [
                "• Build a brand-new dylib from scratch — for anything beyond a one-line change it plans first (goal, files, risks) and only writes code once you approve",
                "• Tap a starter template above the message box on a new chat if you're not sure how to describe what you want",
            ]
        }
        if hasProject {
            lines += ["• In the code editor: the search icon finds any symbol across the whole project and jumps straight to it, with references"]
        }
        if hasLiveTools {
            lines += [
                "• Push a change to everyone without a new build — colours, hiding/reordering tools, a banner, even new screens",
                "• Write a new on-device tool (a recipe) for the Tools tab",
            ]
        }
        lines += [
            "• Generate or search for an image, send a GIF, or type a hex code (or \"colour wheel\") to recolour the app instantly",
        ]
        return lines.joined(separator: "\n")
    }

    static func infoText() async -> String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        var model = "unknown"
        var modelDeep: String?
        var serverOk: Bool?
        do {
            struct Health: Decodable { var main: Probe?; var model: String?; var modelDeep: String? }
            struct Probe: Decodable { var ok: Bool? }
            let h: Health = try await Api.shared.get("/api/ai/health")
            serverOk = h.main?.ok
            if let m = h.model, !m.isEmpty, m.lowercased() != "local" { model = m }
            if let d = h.modelDeep, !d.isEmpty, d != h.model { modelDeep = d }
        } catch { /* show what we have without it */ }

        var lines = [
            "**Uncrypt**",
            "Version \(version) (build \(build))",
            "Developer: MRzefv",
            "Model: \(model)",
        ]
        if let modelDeep { lines.append("Fix/deep model: \(modelDeep)") }
        if let serverOk { lines.append(serverOk ? "Server: reachable" : "Server: not responding right now") }
        lines.append("Runs on Uncrypt's own server; this app is the client for it.")
        return lines.joined(separator: "\n")
    }
}
