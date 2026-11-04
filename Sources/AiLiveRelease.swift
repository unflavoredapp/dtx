import SwiftUI

// MARK: - propose_live_release: the AI drafts a Live Update release, the person reviews the diff and taps Publish

/// The model proposes CHANGES (accent, hidden / ordered tools, a banner, flags…). The server merges them onto the release
/// people have now, cleans the result with the app's own rules and returns the exact diff. Nothing is published until
/// the person taps Publish, and the server signs and publishes what it derived itself, never raw model output.
enum AiLiveRelease {
    static let name = "propose_live_release"

    static let schema: [String: Any] = [
        "type": "function",
        "function": [
            "name": name,
            "description": "Drafts a Live Update release that changes the app for people without a new IPA: accent colour, hiding or ordering tools, an announcement banner, feature flags, experimental switches, and whole NEW SCREENS built from data. It does NOT publish: the person sees the exact diff (and a preview of screens) and taps Publish. Releases go to the beta channel unless the person asks for another. Only include the fields that should change. Never claim it is published. SCREENS: each is {id (letters/digits/-), title, icon (an SF Symbol name), show: [\"sidebar\"] and/or [\"home\"] (home = the block shown on an empty new chat), body: [nodes]}; a screen with an existing id replaces it. A node is {t, ...}: text{text, style:title|headline|body|caption|mono, color, align:left|center|right}; image{symbol, size, color}; button{title, icon, style:primary|glass|plain, action}; stack{axis:v|h, children:[nodes]}; card{title, children:[nodes]}; divider; spacer{size}; list{items:[{title, subtitle, icon, action}]}; kv{rows:[{k, v}]}; badge{text, color}; toggle{key, title, on}. Colours: accent|secondary|white|red|green|orange|yellow|blue. An action is {type:\"open_url\", url:https} | {type:\"open_screen\", screen:id} | {type:\"ask_ai\", text} (sends that text to the chat) | {type:\"copy\", text} | {type:\"sync\"} | {type:\"close\"}. Screens can only use these building blocks; no code.",
            "parameters": [
                "type": "object",
                "properties": [
                    "note": ["type": "string", "description": "One short line for the app's update history, e.g. \"Orange accent + hide Binary\"."],
                    "accent": ["type": "string", "description": "New accent colour as a 6-digit hex, or \"default\" to go back to the app's own."],
                    "hide": ["type": "array", "items": ["type": "string"], "description": "Tool ids to hide."],
                    "show": ["type": "array", "items": ["type": "string"], "description": "Tool ids to un-hide."],
                    "order": ["type": "array", "items": ["type": "string"], "description": "Tool ids in the order they should appear."],
                    "flags": ["type": "object", "additionalProperties": ["type": "boolean"], "description": "Feature flags to set."],
                    "auto": ["type": "object", "additionalProperties": ["type": "boolean"], "description": "Tool id -> run by default."],
                    "banner": ["type": "object", "properties": ["title": ["type": "string"], "text": ["type": "string"], "url": ["type": "string"]], "required": ["title"],
                               "description": "An announcement banner (https link optional)."],
                    "clear_banner": ["type": "boolean", "description": "Remove the current banner."],
                    "screens": ["type": "array", "items": ["type": "object"], "description": "Screens to add or replace (see the description for the format)."],
                    "remove_screens": ["type": "array", "items": ["type": "string"], "description": "Ids of screens to remove."],
                    "channel": ["type": "string", "enum": ["beta", "stable", "experimental"], "description": "Who gets it. Default beta."],
                ],
                "required": ["note"],
            ] as [String: Any],
        ] as [String: Any],
    ]

    struct Parsed { var changes: [String: Any]; var note: String; var channel: String }

    static func parse(_ arguments: String) -> Parsed? {
        guard let d = arguments.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        var ch: [String: Any] = [:]
        if let a = o["accent"] as? String, !a.isEmpty { ch["accent"] = a }
        for k in ["hide", "show", "order"] { if let v = o[k] as? [String], !v.isEmpty { ch[k] = v } }
        for k in ["flags", "auto"] { if let v = o[k] as? [String: Any], !v.isEmpty { ch[k] = v } }
        if let b = o["banner"] as? [String: Any], (b["title"] as? String)?.isEmpty == false { ch["banner"] = b }
        if (o["clear_banner"] as? Bool) == true { ch["clearBanner"] = true }
        if let sc = o["screens"] as? [[String: Any]], !sc.isEmpty { ch["screens"] = sc }
        if let rs = o["remove_screens"] as? [String], !rs.isEmpty { ch["removeScreens"] = rs }
        guard !ch.isEmpty else { return nil }
        let note = ((o["note"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = (o["channel"] as? String).flatMap { ["beta", "stable", "experimental"].contains($0) ? $0 : nil } ?? "beta"
        return Parsed(changes: ch, note: note.isEmpty ? "Update from Ai-Decrypt" : String(note.prefix(120)), channel: channel)
    }

    struct DiffLine: Decodable, Hashable { var kind: String; var text: String }
    struct DraftReply: Decodable { var ok: Bool?; var channel: String?; var percent: Int?; var baseRev: Int?; var diff: [DiffLine]?; var warnings: [String]?; var screens: [LiveScreen]? }
    struct PublishReply: Decodable { var ok: Bool?; var rev: Int? }
    struct ActionReply: Decodable { var ok: Bool?; var state: String? }

    /// Sends the changes to the server for merging + cleaning. Nothing is stored.
    static func draft(changes: [String: Any], note: String, channel: String, percent: Int) async throws -> Draft {
        let r: DraftReply = try await Api.shared.post("/api/staff/live/draft", json: ["changes": changes, "note": note, "channel": channel, "percent": percent])
        let json = (try? JSONSerialization.data(withJSONObject: changes)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return Draft(changesJSON: json, note: note, channel: r.channel ?? channel, percent: r.percent ?? percent, baseRev: r.baseRev ?? 0,
                     diff: r.diff ?? [], warnings: r.warnings ?? [], screens: (r.screens ?? []).compactMap { $0.sanitized() })
    }

    struct Draft: Equatable {
        var changesJSON: String
        var note: String
        var channel: String
        var percent: Int
        var baseRev: Int
        var diff: [DiffLine]
        var warnings: [String]
        var screens: [LiveScreen] = []      // the added / changed screens, for the preview
        var changes: [String: Any] { (changesJSON.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }
        static func == (a: Draft, b: Draft) -> Bool { a.changesJSON == b.changesJSON && a.note == b.note && a.channel == b.channel && a.percent == b.percent && a.baseRev == b.baseRev }
    }

    /// The tool is only offered to staff; the server refuses everyone else anyway.
    static var available: Bool { UserDefaults.standard.bool(forKey: "dt.me.staff") }
}

extension AiDecryptViewModel {
    /// Runs the draft for a `propose_live_release` call, puts the review card on `messages[index]` and returns what the model should be told.
    func proposeLiveRelease(arguments: String, into index: Int) async -> String {
        guard let p = AiLiveRelease.parse(arguments) else { return "Nothing to change: give at least one of accent, hide, show, order, flags, auto, banner." }
        do {
            let d = try await AiLiveRelease.draft(changes: p.changes, note: p.note, channel: p.channel, percent: 100)
            guard index < messages.count else { return "Cancelled." }
            if messages[index].content.hasPrefix("Running ") { messages[index].content = "" }
            messages[index].card = .liveRelease(d)
            return "A draft release is on screen with the exact diff (\(d.diff.count) change(s)). NOTHING is published until the person taps Publish. Say what it changes in one or two lines and tell them to review it."
        } catch {
            return "The draft failed: \(error.localizedDescription). Tell the person plainly; nothing was published."
        }
    }
}

// MARK: - Review card

struct AiLiveReleaseCard: View {
    @State var draft: AiLiveRelease.Draft
    @State private var working = false
    @State private var error: String?
    @State private var publishedRev: Int?
    @State private var withdrawn = false
    @State private var dismissed = false
    @State private var previewing = false

    var body: some View {
        if dismissed {
            Label("Draft discarded. Nothing was published.", systemImage: "xmark.circle").font(.footnote).foregroundStyle(.secondary).padding(.vertical, 4)
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: publishedRev == nil ? "shippingbox" : "shippingbox.fill").foregroundStyle(Color.dtAccent)
                Text(publishedRev.map { "Release #\($0)" } ?? "Draft release").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Spacer(minLength: 0)
                Text(publishedRev == nil ? "Not published" : (withdrawn ? "Withdrawn" : "Live")).font(.caption2.bold())
                    .foregroundStyle(publishedRev == nil ? Color.orange : (withdrawn ? Color.secondary : Color.dtAccent))
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.white.opacity(0.08)))
            }
            Text(draft.note).font(.footnote).foregroundStyle(.secondary)

            if publishedRev == nil {
                Picker("Channel", selection: Binding(get: { draft.channel }, set: { c in Task { await redraft(channel: c) } })) {
                    Text("Beta").tag("beta"); Text("Stable").tag("stable"); Text("Experimental").tag("experimental")
                }.pickerStyle(.segmented).disabled(working)
                HStack {
                    Text("Goes to").font(.footnote).foregroundStyle(.secondary)
                    Menu {
                        ForEach([5, 10, 25, 50, 100], id: \.self) { n in Button("\(n)% of eligible people") { draft.percent = n } }
                    } label: { Text("\(draft.percent)%").font(.footnote.bold()).foregroundStyle(Color.dtAccent) }
                    Text(draft.channel == "stable" ? "· everyone on stable and up" : "· \(draft.channel) channel and up").font(.footnote).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(draft.diff.enumerated()), id: \.offset) { _, l in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(l.kind)).font(.system(size: 12)).foregroundStyle(Color.dtAccent).frame(width: 16)
                        Text(l.text).font(.system(size: 13)).foregroundStyle(.white)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(10).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))

            if !draft.screens.isEmpty {
                Button { previewing = true } label: {
                    Label("Preview \(draft.screens.count == 1 ? "screen" : "\(draft.screens.count) screens")", systemImage: "rectangle.on.rectangle")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.dtAccent)
                }
            }
            ForEach(draft.warnings, id: \.self) { w in Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            if let e = error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(5) }

            HStack(spacing: 8) {
                if working { ProgressView().scaleEffect(0.8) }
                if publishedRev == nil {
                    Button { Task { await publish() } } label: {
                        Label("Publish", systemImage: "paperplane.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.dtOnAccent)
                            .padding(.horizontal, 16).padding(.vertical, 9).background(Capsule().fill(Color.dtAccent))
                    }.disabled(working)
                    Button { dismissed = true } label: {
                        Text("Discard").font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 9).aiGlass(Capsule())
                    }.disabled(working)
                } else if !withdrawn {
                    Button { Task { await LiveSync.shared.sync() } } label: {
                        Label("Sync this phone", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.dtOnAccent)
                            .padding(.horizontal, 16).padding(.vertical, 9).background(Capsule().fill(Color.dtAccent))
                    }
                    Button { Task { await withdraw() } } label: {
                        Text("Withdraw").font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 9).aiGlass(Capsule())
                    }.disabled(working)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.115)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5))
        .sheet(isPresented: $previewing) { AiLivePreviewSheet(screens: draft.screens) }
    }

    private func icon(_ kind: String) -> String {
        switch kind {
        case "accent": return "paintpalette"; case "hide", "order": return "square.grid.2x2"; case "banner": return "megaphone"
        case "experimental": return "flask"; case "screen": return "rectangle.on.rectangle"; default: return "slider.horizontal.3"
        }
    }

    /// The channel decides which release the change is merged onto, so the diff is asked for again.
    private func redraft(channel: String) async {
        working = true; error = nil; defer { working = false }
        do {
            let d = try await AiLiveRelease.draft(changes: draft.changes, note: draft.note, channel: channel, percent: draft.percent)
            draft = d
        } catch { self.error = error.localizedDescription }
    }

    private func publish() async {
        working = true; error = nil; defer { working = false }
        let body: [String: Any] = ["changes": draft.changes, "note": draft.note, "channel": draft.channel, "percent": draft.percent, "baseRev": draft.baseRev]
        do {
            let r: AiLiveRelease.PublishReply = try await Api.shared.post("/api/staff/live/publish", json: body)
            publishedRev = r.rev
        } catch { self.error = error.localizedDescription }
    }

    private func withdraw() async {
        guard let rev = publishedRev else { return }
        working = true; error = nil; defer { working = false }
        do {
            let _: AiLiveRelease.ActionReply = try await Api.shared.post("/api/staff/live/releases/\(rev)/rollback", json: [:])
            withdrawn = true
        } catch { self.error = error.localizedDescription }
    }
}

/// Shows the screens of a draft exactly as the app would draw them once published.
struct AiLivePreviewSheet: View {
    let screens: [LiveScreen]
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                if screens.indices.contains(index) {
                    LiveScreenBody(screen: screens[index], screens: screens, onClose: { dismiss() }).padding(16)
                }
            }
            .background(AppBackground())
            .navigationTitle(screens.indices.contains(index) ? screens[index].title : "Preview").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if screens.count > 1 {
                    ToolbarItem(placement: .bottomBar) {
                        Picker("Screen", selection: $index) { ForEach(Array(screens.enumerated()), id: \.offset) { i, s in Text(s.title).tag(i) } }.pickerStyle(.segmented)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.dtAccent)
    }
}
