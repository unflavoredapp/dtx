import Foundation

// MARK: - The plugin system
//
// A tool is one small piece of work that takes an IPA link and answers with sections to show (key/value rows, lists, tables, text).
// Tools come from two places and show up together in the Tools tab:
//   • bundled tools live inside the app (Tools/BuiltinTools.swift) and run on the phone, so they work with no server at all
//   • recipes are small JSON tools the server hands out; the app runs them on the phone (Tools/Recipes.swift)
//   • server tools are whatever your backend lists at /api/plugins, run as jobs on the server (Tools/ServerTools.swift)
// To add a bundled tool: write a `Tool` (id, name, summary, icon, options, run) and add it to ToolRegistry.bundled.
// A bundled tool can also call your backend itself with Api.shared when it needs the server's engine.

/// What a tool gets when it runs.
struct ToolContext {
    let url: URL
    /// Every option's value as text ("true" / "false" for switches).
    let options: [String: String]
    /// Shows a progress line under the tool.
    let say: (String) -> Void
    /// Set when the tool is running against a file attached directly in a chat (Ai-Decrypt) rather than a remote IPA link.
    /// When this is set, `ZipSource.open(_:)` reads the file straight off disk instead of making range requests against `url`.
    var localFile: URL? = nil

    func flag(_ key: String) -> Bool { options[key] == "true" }
}

struct Tool: Identifiable {
    enum Origin { case bundled, recipe, server }
    let id: String
    let name: String
    let summary: String
    let icon: String                 // an SF Symbol
    let origin: Origin
    var options: [PluginOption] = []
    /// Runs by itself in the background when an app opens (the person can switch this per tool).
    var auto: Bool = false
    /// Shown in Settings > Plugins; a change since the person last looked marks the tool as updated.
    var version: String = ""
    let run: (ToolContext) async throws -> [PluginSection]
}

/// Whether a tool (bundled, recipe, or server) is aimed at dylibs/frameworks/the binary itself, going only by
/// its id/name/summary — there's no separate tagging system, so this is a plain keyword match.
func isDylibTool(_ t: Tool) -> Bool {
    let s = (t.id + " " + t.name + " " + t.summary).lowercased()
    return s.contains("dylib") || s.contains("binary") || s.contains("librar") || s.contains("framework")
}

enum ToolRegistry {
    /// The tools that ship inside the app.
    static let bundled: [Tool] = [
        BuiltinTools.appInfo,
        BuiltinTools.package,
        BuiltinTools.rawPlist,
        BuiltinTools.linkCheck,
        MoreTools.binary,
        MoreTools.bundles,
        MoreTools.privacy,
    ]
}
