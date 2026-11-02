import Foundation

/// Runs tools and remembers their answers, so a tool started in the background is still there when you open it.
@MainActor
final class ToolRunner: ObservableObject {
    static let shared = ToolRunner()

    struct State {
        var running = false
        var done = false
        var failed = false
        var message = ""
        var sections: [PluginSection] = []
    }

    @Published private(set) var states: [String: State] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    static func key(_ t: Tool, _ url: String) -> String { t.id + "|" + url }
    func state(_ t: Tool, _ url: String) -> State { states[Self.key(t, url)] ?? State() }

    /// Option values to use when the person hasn't touched anything.
    static func defaults(_ t: Tool) -> [String: String] {
        Dictionary(uniqueKeysWithValues: t.options.map { ($0.key, $0.def) })
    }

    func start(_ t: Tool, url: String, options: [String: String]? = nil) {
        guard let u = URL(string: url) else { return }
        let k = Self.key(t, url)
        guard !(states[k]?.running ?? false) else { return }
        states[k] = State(running: true, message: "Starting…")
        let opts = options ?? Self.defaults(t)
        let ctx = ToolContext(url: u, options: opts, say: { [weak self] m in Task { @MainActor in self?.states[k]?.message = m } })
        tasks[k] = Task { [weak self] in
            do {
                let out = try await t.run(ctx)
                self?.states[k] = State(done: true, message: out.isEmpty ? "The tool had nothing to report." : "", sections: out)
            } catch is CancellationError {
                self?.states[k] = State(message: "Stopped.")
            } catch {
                self?.states[k] = State(done: true, failed: true, message: error.localizedDescription)
            }
            self?.tasks[k] = nil
        }
    }

    func stop(_ t: Tool, _ url: String) { tasks[Self.key(t, url)]?.cancel() }
}

/// Which tools run by themselves. Starts from each tool's own default; the person can change it.
enum ToolPrefs {
    static func auto(_ t: Tool) -> Bool {
        let d = UserDefaults.standard
        return d.object(forKey: "dt.tool.auto." + t.id) as? Bool ?? t.auto
    }
    static func setAuto(_ t: Tool, _ on: Bool) { UserDefaults.standard.set(on, forKey: "dt.tool.auto." + t.id) }
}
