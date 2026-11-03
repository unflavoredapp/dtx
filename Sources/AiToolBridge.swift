import Foundation

/// Lets the Ai-Decrypt chat model call into the app's own bundled analysis tools (App Info, Package Contents,
/// Raw Info.plist, Link Check, Binary Inspector, Embedded Bundles, Privacy Manifest) against a .zip/.ipa/.dylib
/// the person attached directly in the chat. Server-run tools (Repo Studio, Decrypt & Inject, the Ghidra/dylib
/// decompile engine) aren't wired in here yet — they all require the file to already be reachable at an https
/// URL on decrypt.team, and a locally-attached file has no URL until it's uploaded there.
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
