import Foundation

/// The tools your backend offers. The app asks /api/plugins what exists, and runs each as a job on the server.
enum ServerTools {
    enum Status {
        case ok(Int)
        case unavailable(String)
    }

    static func load() async -> ([Tool], Status) {
        do {
            let r: PluginList = try await Api.shared.get("/api/plugins")
            let tools = (r.items ?? []).map { p in
                Tool(id: "server-" + p.id, name: p.name, summary: p.description, icon: "server.rack", origin: .server,
                     capabilities: p.capabilities, options: p.options, version: p.version,
                     run: { ctx in try await run(p, ctx) })
            }
            return (tools, .ok(tools.count))
        } catch let e as ApiError where e.status == 404 {
            return ([], .unavailable("This server has no plugin engine yet (it doesn't answer /api/plugins). The bundled tools above still work."))
        } catch {
            return ([], .unavailable("Couldn't reach the server's tools: " + error.localizedDescription))
        }
    }

    private static func run(_ p: PluginInfo, _ ctx: ToolContext) async throws -> [PluginSection] {
        var opts: [String: Any] = [:]
        for o in p.options { opts[o.key] = o.type == "bool" ? (ctx.options[o.key] == "true") : (ctx.options[o.key] ?? o.def) }
        ctx.say("Starting on the server…")
        let start: PluginStart = try await Api.shared.post("/api/plugins/\(p.id)/run", json: ["src": ["url": ctx.url.absoluteString], "options": opts])
        guard let job = start.id, !job.isEmpty else { throw ApiError.server("The server didn't start the tool.", 0) }
        do {
            while true {
                try Task.checkCancellation()
                let j: PluginJob = try await Api.shared.get("/api/plugins/jobs/" + job)
                switch j.status ?? "" {
                case "done": return j.result?.sections ?? []
                case "err": throw ApiError.server(j.error ?? "The tool failed.", 0)
                case "cancel": throw CancellationError()
                default: ctx.say((j.msg ?? "Working…") + ((j.pct ?? 0) > 0 ? " · \(j.pct ?? 0)%" : ""))
                }
                try await Task.sleep(nanoseconds: 1_200_000_000)
            }
        } catch is CancellationError {
            Task { let _: PluginStart? = try? await Api.shared.post("/api/plugins/jobs/\(job)/cancel") }
            throw CancellationError()
        }
    }
}
