import Foundation

/// Lets the chat model reach the app's tools two ways:
///   • one function per bundled analysis tool (App Info, Package Contents, Raw Info.plist, Link Check, Binary
///     Inspector, Embedded Bundles, Privacy Manifest), run against a .zip/.ipa/.dylib attached directly in chat.
///   • run_tool/list_tools, which run ANY tool — bundled, a published recipe, or a server tool — against an
///     app's https IPA link, so the model can reach for a recipe someone's published (e.g. a dylib-branding
///     recipe) the same turn, without the person leaving the chat to paste a link into a separate screen.
enum AiToolBridge {
    /// One function per bundled tool, named after its id with dashes turned into underscores (OpenAI function
    /// names can't contain dashes reliably across every backend, so this keeps it boring and portable).
    static func toolSchemas() -> [[String: Any]] {
        ToolRegistry.bundled.map { t in
            [
                "type": "function",
                "function": [
                    "name": schemaName(t.id),
                    "description": t.summary,
                    "parameters": ["type": "object", "properties": [String: Any](), "required": []] as [String: Any],
                ] as [String: Any],
            ]
        }
    }

    static func schemaName(_ id: String) -> String { id.replacingOccurrences(of: "-", with: "_") }

    static func tool(named name: String) -> Tool? {
        ToolRegistry.bundled.first { schemaName($0.id) == name }
    }

    // MARK: - run_tool / list_tools (bundled + recipes + server tools, against an IPA link)

    static let listToolsSchema: [String: Any] = [
        "type": "function",
        "function": [
            "name": "list_tools",
            "description": "Lists every analysis tool available right now — built in, published recipes, and server tools — with its id and what it does. Call this before run_tool if you don't already know the right tool_id.",
            "parameters": [
                "type": "object",
                "properties": [
                    "dylib_only": ["type": "boolean", "description": "Only list tools aimed at dylibs, frameworks or the binary itself. Use this when the person is asking about dylibs/injection/branding."],
                ],
                "required": [],
            ] as [String: Any],
        ] as [String: Any],
    ]

    static let runToolSchema: [String: Any] = [
        "type": "function",
        "function": [
            "name": "run_tool",
            "description": "Runs one analysis tool (bundled, a published recipe, or a server tool) against an app's IPA and returns its findings. Get tool_id from list_tools, or use a known bundled id directly (app-info, package, raw-plist, link-check, binary, bundles, privacy).",
            "parameters": [
                "type": "object",
                "properties": [
                    "tool_id": ["type": "string", "description": "The tool's id, exactly as list_tools (or a search_apps/library result) gave it."],
                    "ipa_url": ["type": "string", "description": "https link to the .ipa to run the tool against."],
                ],
                "required": ["tool_id", "ipa_url"],
            ] as [String: Any],
        ] as [String: Any],
    ]

    /// Every tool available right now, from all three sources.
    private static func allTools() async -> [Tool] {
        async let recipes = RecipeStore.load()
        let (server, _) = await ServerTools.load()
        return ToolRegistry.bundled + (await recipes) + server
    }

    static func listTools(dylibOnly: Bool) async -> String {
        let all = await allTools()
        let shown = dylibOnly ? all.filter(isDylibTool) : all
        guard !shown.isEmpty else { return dylibOnly ? "No tools aimed at dylibs are published yet." : "No tools available right now." }
        return shown.map { "- \($0.id): \($0.name) — \($0.summary)" }.joined(separator: "\n")
    }

    static func runTool(toolID: String, ipaURL: String) async -> String {
        guard let u = URL(string: ipaURL), u.scheme == "https" else { return "\"\(ipaURL)\" isn't a usable https IPA link." }
        guard let tool = await allTools().first(where: { $0.id == toolID }) else {
            return "No tool with id \"\(toolID)\". Call list_tools to see what's available."
        }
        let ctx = ToolContext(url: u, options: await ToolRunner.defaults(tool), say: { _ in })
        do { return render(try await tool.run(ctx)) }
        catch { return "Tool error: \(error.localizedDescription)" }
    }

    static func runToolArgs(_ arguments: String) -> (toolID: String, ipaURL: String) {
        guard let d = arguments.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return ("", "") }
        return ((o["tool_id"] as? String) ?? "", (o["ipa_url"] as? String) ?? "")
    }

    static func listToolsDylibOnly(_ arguments: String) -> Bool {
        guard let d = arguments.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return (o["dylib_only"] as? Bool) ?? false
    }

    /// Runs a bundled tool against a file attached in chat and renders its sections as plain text for the model
    /// to read back (and for us to show under the tool-call bubble).
    static func run(_ tool: Tool, fileURL: URL) async -> String {
        let ctx = ToolContext(url: fileURL, options: [:], say: { _ in }, localFile: fileURL)
        do {
            let sections = try await tool.run(ctx)
            return render(sections)
        } catch {
            return "Tool error: \(error.localizedDescription)"
        }
    }

    private static func render(_ sections: [PluginSection]) -> String {
        var out = ""
        for s in sections {
            out += "## \(s.title)\n"
            switch s.kind {
            case "kv", "table":
                for row in s.rows { out += "- " + row.joined(separator: ": ") + "\n" }
            case "list":
                for item in s.items { out += "- \(item)\n" }
            case "text":
                out += s.text + "\n"
            default:
                break
            }
            if !s.note.isEmpty { out += "Note: \(s.note)\n" }
            out += "\n"
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "(no output)" }
        return trimmed.count > 8000 ? String(trimmed.prefix(8000)) + "\n…(truncated)" : trimmed
    }
}
