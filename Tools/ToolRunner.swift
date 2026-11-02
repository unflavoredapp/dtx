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

    /// The most recent finished answer for a tool, whichever IPA it was for.
    func last(_ t: Tool) -> (url: String, state: State)? {
        states.first { $0.key.hasPrefix(t.id + "|") && $0.value.done }.map { (String($0.key.dropFirst(t.id.count + 1)), $0.value) }
    }

    func stop(_ t: Tool, _ url: String) { tasks[Self.key(t, url)]?.cancel() }
}

/// Which tools run by themselves and which are switched on. Starts from each tool's own default and from the live configuration; the person can change both.
@MainActor
enum ToolPrefs {
    static func auto(_ t: Tool) -> Bool {
        UserDefaults.standard.object(forKey: "dt.tool.auto." + t.id) as? Bool ?? LiveSync.shared.config.auto?[t.id] ?? t.auto
    }
    static func setAuto(_ t: Tool, _ on: Bool) { UserDefaults.standard.set(on, forKey: "dt.tool.auto." + t.id) }

    /// Off when the person switched it off, or when a live release hides it and they haven't switched it on themselves.
    static func enabled(_ t: Tool) -> Bool {
        if let own = UserDefaults.standard.object(forKey: "dt.tool.on." + t.id) as? Bool { return own }
        return !(LiveSync.shared.config.hide ?? []).contains(t.id)
    }
    static func setEnabled(_ t: Tool, _ on: Bool) { UserDefaults.standard.set(on, forKey: "dt.tool.on." + t.id) }
    static func hasOwnChoice(_ t: Tool) -> Bool {
        UserDefaults.standard.object(forKey: "dt.tool.on." + t.id) != nil || UserDefaults.standard.object(forKey: "dt.tool.auto." + t.id) != nil
    }
    static func reset(_ t: Tool) {
        UserDefaults.standard.removeObject(forKey: "dt.tool.on." + t.id); UserDefaults.standard.removeObject(forKey: "dt.tool.auto." + t.id)
    }

    /// Only the tools that are switched on, in the order a live release asks for (the rest keep their own order after those).
    static func arrange(_ tools: [Tool]) -> [Tool] {
        let order = LiveSync.shared.config.order ?? []
        let on = tools.filter { enabled($0) }
        return on.enumerated().sorted { a, b in
            let ia = order.firstIndex(of: a.element.id) ?? Int.max, ib = order.firstIndex(of: b.element.id) ?? Int.max
            return ia != ib ? ia < ib : a.offset < b.offset
        }.map { $0.element }
    }

    /// "new" the first time a tool is seen, "updated" when its version changed since the person last opened it in Settings.
    static func seenState(_ t: Tool) -> String? {
        let k = "dt.tool.seen." + t.id, d = UserDefaults.standard
        guard let was = d.string(forKey: k) else { return "NEW" }
        return was != t.version ? "UPDATED" : nil
    }
    static func markSeen(_ t: Tool) { UserDefaults.standard.set(t.version, forKey: "dt.tool.seen." + t.id) }
}
