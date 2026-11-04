import SwiftUI

// MARK: - propose_recipe: the AI writes an on-device tool as data; you test it on a real IPA, then publish

/// A recipe is a tool written as JSON (read a plist / text file, list files, show key-values, lists, tables). The app runs it on
/// the phone with its own steps, so nothing downloaded is ever code. The server checks every recipe again before it is saved.
/// A published recipe appears in the Tools tab for everyone signed in, so the card says that and tests it first.
enum AiRecipeTool {
    static let name = "propose_recipe"

    static let schema: [String: Any] = [
        "type": "function",
        "function": [
            "name": name,
            "description": "Writes a new on-device TOOL (a recipe) that inspects an IPA, for the Tools tab. It does NOT publish: the person tests it on a real IPA and taps Publish. A recipe is {id (lowercase letters, digits, dashes), name, summary, icon (an SF Symbol), version, options?:[{key,label,type:text|bool|number,def}], steps:[...], output:[...]}. STEPS read things out of the IPA, each stored under a short name (\"as\"): {op:\"plist\", file:\"Payload/*.app/Info.plist\", as:\"info\"} unpacks a property list; {op:\"text\", file, as} a text file; {op:\"glob\", match:\"Payload/*.app/Frameworks/*.dylib\", as} lists files whose path matches; {op:\"dirs\", match, as} lists folders. \"*\" matches inside one folder level only. Add optional:true to a step that may be missing. OUTPUT sections show results; {name.Key} inserts a value, {name.count} a list's size, {n} the row count, {opt.key} an option: {kind:\"kv\", title, rows:[[\"Label\",\"{info.CFBundleName}\"]]}; {kind:\"list\", title, from:\"fw\" or \"info.UIBackgroundModes\", basename:true, strip, filter, limit}; {kind:\"table\", title, from:\"info\", prefix:\"NS\", suffix:\"UsageDescription\"} or rows:[[a,b]]; {kind:\"text\", title, from:\"t\"} or text. Only these steps and sections exist: it can read and list, not run code or change files.",
            "parameters": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"], "name": ["type": "string"], "summary": ["type": "string"], "icon": ["type": "string"], "version": ["type": "string"],
                    "options": ["type": "array", "items": ["type": "object"]],
                    "steps": ["type": "array", "items": ["type": "object"]],
                    "output": ["type": "array", "items": ["type": "object"]],
                ],
                "required": ["id", "name", "steps", "output"],
            ] as [String: Any],
        ] as [String: Any],
    ]

    static var available: Bool { UserDefaults.standard.bool(forKey: "dt.me.staff") }

    struct Draft: Equatable {
        var recipeJSON: String
        var hash: String
        var exists: Bool
        var existingVersion: String?
        var warnings: [String]
        var lines: [String]
        var testURL: String
        var recipe: [String: Any] { (recipeJSON.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }
        var name: String { (recipe["name"] as? String) ?? "Recipe" }
        var id: String { (recipe["id"] as? String) ?? "" }
        static func == (a: Draft, b: Draft) -> Bool { a.recipeJSON == b.recipeJSON && a.hash == b.hash }
    }

    static func draft(_ recipe: [String: Any], testURL: String) async throws -> Draft {
        let data = try await Api.shared.request("POST", "/api/staff/live/recipes/draft", json: ["recipe": recipe])
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rec = o["recipe"] as? [String: Any],
              let json = (try? JSONSerialization.data(withJSONObject: rec)).flatMap({ String(data: $0, encoding: .utf8) }) else {
            throw ApiError.server("The server's answer wasn't a recipe.", 0)
        }
        return Draft(recipeJSON: json, hash: (o["hash"] as? String) ?? "", exists: (o["exists"] as? Bool) ?? false,
                     existingVersion: o["existingVersion"] as? String, warnings: (o["warnings"] as? [String]) ?? [],
                     lines: (o["lines"] as? [String]) ?? [], testURL: testURL)
    }
}

extension AiDecryptViewModel {
    /// The IPA link of the newest app in this chat, offered as the default for a recipe's test run.
    var latestIPAURL: String {
        for m in messages.reversed() { if case .libraries(let lib)? = m.card, let u = lib.ipaURL { return u } }
        return ""
    }

    func proposeRecipe(arguments: String, into index: Int) async -> String {
        guard let d = arguments.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], !o.isEmpty else {
            return "The recipe arguments were not valid JSON. Try again with id, name, steps and output."
        }
        do {
            let draft = try await AiRecipeTool.draft(o, testURL: latestIPAURL)
            guard index < messages.count else { return "Cancelled." }
            if messages[index].content.hasPrefix("Running ") { messages[index].content = "" }
            messages[index].card = .recipe(draft)
            return "A draft recipe \"\(draft.name)\" is on screen with a test-run field. NOTHING is published until the person taps Publish. Say in one line what it shows and suggest testing it on an IPA first." +
                (draft.warnings.isEmpty ? "" : " The server dropped parts of it: " + draft.warnings.joined(separator: " | "))
        } catch {
            return "The recipe was rejected: \(error.localizedDescription). Fix it and call propose_recipe again if the person still wants it; nothing was published."
        }
    }
}

// MARK: - Card

struct AiRecipeCard: View {
    let draft: AiRecipeTool.Draft
    @State private var url: String
    @State private var running = false
    @State private var sections: [PluginSection] = []
    @State private var testNote = ""
    @State private var tested = false
    @State private var working = false
    @State private var error: String?
    @State private var published = false
    @State private var withdrawn = false
    @State private var dismissed = false

    init(draft: AiRecipeTool.Draft) { self.draft = draft; _url = State(initialValue: draft.testURL) }

    var body: some View {
        if dismissed {
            Label("Draft discarded. Nothing was published.", systemImage: "xmark.circle").font(.footnote).foregroundStyle(.secondary).padding(.vertical, 4)
        } else { card }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: (draft.recipe["icon"] as? String) ?? "doc.text.magnifyingglass").foregroundStyle(Color.dtAccent)
                Text(draft.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Spacer(minLength: 0)
                Text(published ? (withdrawn ? "Withdrawn" : "Live") : "Not published").font(.caption2.bold())
                    .foregroundStyle(published && !withdrawn ? Color.dtAccent : (published ? Color.secondary : Color.orange))
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.white.opacity(0.08)))
            }
            if let s = draft.recipe["summary"] as? String, !s.isEmpty { Text(s).font(.footnote).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(draft.lines, id: \.self) { l in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "wrench.and.screwdriver").font(.system(size: 12)).foregroundStyle(Color.dtAccent).frame(width: 16)
                        Text(l).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white)
                        Spacer(minLength: 0)
                    }
                }
                if draft.exists { Label("Replaces the published version\(draft.existingVersion.map { " (v\($0))" } ?? "").", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.orange) }
            }
            .padding(10).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
            ForEach(draft.warnings, id: \.self) { w in Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }

            if !published {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Test it on an IPA first").font(.footnote.weight(.semibold)).foregroundStyle(.white)
                    TextField("https://…/app.ipa", text: $url)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(9).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
                    HStack(spacing: 8) {
                        Button { Task { await test() } } label: {
                            HStack(spacing: 6) { if running { ProgressView().scaleEffect(0.7) }; Text(running ? "Running…" : "Run test") }
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 8).aiGlass(Capsule())
                        }.disabled(running || URL(string: url)?.scheme != "https")
                        if !testNote.isEmpty { Text(testNote).font(.caption).foregroundStyle(tested ? Color.dtAccent : .red).lineLimit(3) }
                    }
                    ForEach(sections) { SectionView(section: $0) }
                }
            }
            if let e = error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(5) }

            HStack(spacing: 8) {
                if working { ProgressView().scaleEffect(0.8) }
                if !published {
                    Button { Task { await publish() } } label: {
                        Label("Publish", systemImage: "paperplane.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.dtOnAccent)
                            .padding(.horizontal, 16).padding(.vertical, 9).background(Capsule().fill(Color.dtAccent))
                    }.disabled(working)
                    Button { dismissed = true } label: {
                        Text("Discard").font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 9).aiGlass(Capsule())
                    }.disabled(working)
                } else if !withdrawn {
                    Text("In the Tools tab for everyone signed in.").font(.footnote).foregroundStyle(Color.dtAccent)
                    Button { Task { await withdraw() } } label: {
                        Text("Withdraw").font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 9).aiGlass(Capsule())
                    }.disabled(working)
                }
                Spacer(minLength: 0)
            }
            if !published && !tested { Text("Publishing puts this tool live for everyone signed in straight away. Withdraw takes it back.").font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.115)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5))
    }

    /// Runs the draft with the app's own recipe runner against the IPA, exactly as it will run once published.
    private func test() async {
        guard let u = URL(string: url), u.scheme == "https", let data = draft.recipeJSON.data(using: .utf8),
              let rec = try? JSONDecoder().decode(Recipe.self, from: data) else { testNote = "That isn't a valid https link."; tested = false; return }
        running = true; sections = []; testNote = "Opening the IPA…"; tested = false
        defer { running = false }
        let opts = Dictionary(uniqueKeysWithValues: (rec.options ?? []).map { ($0.key, $0.def) })
        do {
            let out = try await RecipeRunner.run(rec, ToolContext(url: u, options: opts, say: { m in testNote = m }))
            sections = out
            tested = true
            testNote = out.isEmpty ? "It ran but found nothing to show for this IPA." : "Worked: \(out.count) section(s)."
        } catch { tested = false; testNote = error.localizedDescription }
    }

    private func publish() async {
        working = true; error = nil; defer { working = false }
        do {
            let _ = try await Api.shared.request("POST", "/api/staff/live/recipes/publish", json: ["recipe": draft.recipe, "hash": draft.hash])
            published = true
            await ToolCatalog.shared.load()
        } catch { self.error = error.localizedDescription }
    }

    private func withdraw() async {
        working = true; error = nil; defer { working = false }
        do {
            let _ = try await Api.shared.request("POST", "/api/staff/live/recipes/\(draft.id)/withdraw", json: ["restore": draft.exists])
            withdrawn = true
            await ToolCatalog.shared.load()
        } catch { self.error = error.localizedDescription }
    }
}
