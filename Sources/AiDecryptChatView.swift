//
//  AiDecryptChatView.swift
//  Decrypt.Team
//
//  Native chat screen for the Ai-Decrypt assistant, matching the app's
//  existing dark/lime theme (Theme.swift) and Api.shared conventions.
//  Talks to the llama.cpp OpenAI-compatible endpoint, proxied through
//  Apache at https://ai.decrypt.team/v1/chat/completions.
//
//  Three extra capabilities on top of plain chat:
//  - Attaching a .zip/.ipa/.dylib gives the model function-calling access to the app's bundled
//    analysis tools (see AiToolBridge.swift and Tools/LocalZip.swift).
//  - Attaching a photo routes the turn to a vision-capable model/endpoint (see AiDecryptAPI.visionEndpoint)
//    so the model can look at screenshots, mockups, or a photo of an error.
//  - The model can call `generate_image` at any time (see AiImageGen.swift) to make and show a picture.
//

import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import UIKit

// MARK: - Model

struct AiToolCallResult: Equatable {
    let id: String
    let name: String
    /// Raw (and, mid-stream, possibly partial) JSON text of the call's arguments, e.g. {"prompt":"..."}.
    let arguments: String
}

struct AiChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant, system, tool }
    let id = UUID()
    let role: Role
    var content: String
    /// A photo the person attached (role .user) or a picture the model generated via `generate_image`
    /// (role .assistant) — either way, shown inline under this message's bubble.
    var imageData: Data? = nil
    /// Set on an assistant message that asked to call one or more tools.
    var toolCalls: [AiToolCallResult]? = nil
    /// Set on a `tool` message: which call this is the result of.
    var toolCallId: String? = nil
    var name: String? = nil
    /// An interactive card shown under this message (app picker, dylib picker). See AiRepoCards.swift.
    var card: AiCard? = nil
    /// "12s · 412 tokens · 17.8 tok/s", set once the reply has finished.
    var meta: String? = nil
    /// An animated GIF shown in this message (sent by the person via the GIF picker, or by the model via `send_gif`).
    var gifURL: String? = nil
    var gifTitle: String? = nil
}

/// Progress signals from the model stream, used for the live indicator and the per-reply token footer.
enum AiStreamEvent { case reasoning, content, toolCall, usage(prompt: Int, completion: Int) }

final class AiStreamSink {
    let handle: (AiStreamEvent) -> Void
    init(_ handle: @escaping (AiStreamEvent) -> Void) { self.handle = handle }
}

struct AiLiveStats: Equatable {
    enum Phase: Equatable { case reading, reasoning, writing, toolCall, running(String), remembering }
    var phase: Phase = .reading
    var startedAt = Date()
    var tokens = 0
    var tps = 0.0
}

/// Interactive cards the repo/decrypt flow shows in the chat.
enum AiCard: Equatable {
    case apps([AppPick])
    case libraries(LibrariesCard)
    case reconResults([ReconResult])
    /// the colour wheel; the payload is the hex it is currently on
    case colorPicker(String)
    /// a proposed code change for a reconstructed project: diff + Apply / Reject
    case patch(jobID: String, patchID: String, name: String)
    /// the app's Live Update status, with Sync now / Update Center
    case live
    /// a drafted Live Update release: exact diff + Publish / Discard
    case liveRelease(AiLiveRelease.Draft)
    /// a drafted on-device tool (recipe): test run + Publish
    case recipe(AiRecipeTool.Draft)
    /// a drafted brand-new dylib: files + Create project
    case dylibDraft(AiDylibTool.Draft)
    /// a created AI-authored dylib project: Build / fix / share
    case authored(jobID: String, name: String)
    /// crash-log mapping: the project, the mapped frames, and the freshness check
    case crash(String, String, [AiCrashTool.Match], AiCrashTool.CheckCrash?)
    /// a proposed dylib plan: goal/files/frameworks/risks, nothing written until approved
    case dylibPlan(AiDylibPlanTool.Plan)
}

struct AppVersionPick: Identifiable, Equatable {
    var id: String { version }
    let version: String
    let ipaURL: String?
}

struct AppPick: Identifiable, Equatable {
    let id: String          // bundle id (deduped)
    let name: String
    let developer: String
    let icon: URL?
    let bid: String
    let repoName: String
    let storeID: String?    // filled from the repo entry's App Store id when available
    var versions: [AppVersionPick]   // newest first, merged across duplicate repo entries
    var current: AppVersionPick? { versions.first }
}

struct LibPick: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let type: String        // "dylib" / "framework"
    let size: Int64
}

struct LibrariesCard: Equatable {
    let bid: String
    let appName: String
    let storeID: String?
    let versions: [AppVersionPick]   // for the version selector
    let currentVersion: String       // the version these items were scanned from
    let ipaURL: String?              // the scanned version's IPA (dylibs are extracted from here)
    let items: [LibPick]             // the app's real bundled dylibs/frameworks, read from the IPA
}

struct AiAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let content: String
}

/// A .zip/.ipa/.dylib attached straight into the chat, saved to a temp file so the bundled Tools can read it
/// (see Tools/LocalZip.swift) without needing an https link anywhere.
struct AiBinaryAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let fileURL: URL
    let size: Int
}

struct AiImageAttachment: Identifiable, Equatable {
    let id = UUID()
    let data: Data
}

// MARK: - API client

enum AiDecryptAPI {
    static let endpoint = URL(string: "https://ai.decrypt.team/v1/chat/completions")!
    static let model = "AiDecrypt"
    /// The text model's context window (llama-server -c). Used for the "left" figure in the usage bar.
    static let contextWindow = 32_768

    /// A second llama-server instance running a vision-capable model (Qwen2-VL or similar, loaded with
    /// --mmproj), proxied at its own path so the text model's endpoint above doesn't have to change.
    static let visionEndpoint = URL(string: "https://ai.decrypt.team/v1vision/chat/completions")!
    static let visionModel = "AiDecryptVision"

    /// A small, separately pinned model for background chores (memory summaries). If that endpoint isn't there the
    /// chore silently runs on the main model instead, and the worker is not tried again this session.
    static let workerEndpoint = URL(string: "https://ai.decrypt.team/v1worker/chat/completions")!
    static let workerModel = "AiDecryptWorker"
    static var workerDown = false

    static func streamWorker(messages: [AiChatMessage], onDelta: @escaping (String) -> Void) async throws {
        if !workerDown {
            var got = ""
            do {
                try await streamChat(messages: messages, tools: nil, endpoint: workerEndpoint, model: workerModel) { got += $0; onDelta($0) }
                return
            } catch {
                workerDown = true
                if !got.isEmpty { return }
            }
        }
        _ = try await streamChat(messages: messages, tools: nil, onDelta: onDelta)
    }

    /// Streams the assistant's reply token-by-token (`onDelta`, called on the main actor) and returns any
    /// tool calls the model asked for once the stream ends. `tools` is the OpenAI-style function list —
    /// pass nil/empty when there's nothing for the model to call.
    ///
    /// Without an explicit max_tokens, llama.cpp falls back to its own low default and cuts replies off
    /// mid-sentence (finish_reason "length") — 4096 gives it real room.
    @discardableResult
    static func streamChat(
        messages: [AiChatMessage],
        tools: [[String: Any]]? = nil,
        endpoint: URL = AiDecryptAPI.endpoint,
        model: String = AiDecryptAPI.model,
        sink: AiStreamSink? = nil,
        thinking: Bool = false,
        onDelta: @escaping (String) -> Void
    ) async throws -> [AiToolCallResult] {
        var request = URLRequest(url: endpoint, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { m -> [String: Any] in
                var d: [String: Any] = ["role": m.role.rawValue]
                if let name = m.name { d["name"] = name }
                if let tcId = m.toolCallId { d["tool_call_id"] = tcId }
                if let calls = m.toolCalls, !calls.isEmpty {
                    d["tool_calls"] = calls.map {
                        ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments.isEmpty ? "{}" : $0.arguments]]
                    }
                }
                if let img = m.imageData {
                    // OpenAI vision format: content becomes an array of text/image_url parts instead of a plain string.
                    var parts: [[String: Any]] = []
                    if !m.content.isEmpty { parts.append(["type": "text", "text": m.content]) }
                    parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + img.base64EncodedString()]])
                    d["content"] = parts
                } else {
                    d["content"] = m.content
                }
                return d
            },
            "stream": true,
            "max_tokens": 4096,
            "stream_options": ["include_usage": true],
            "cache_prompt": true,
            "temperature": thinking ? 0.6 : 0.7,
            "top_p": thinking ? 0.95 : 0.8,
            "top_k": 20,
        ]
        if thinking { body["chat_template_kwargs"] = ["enable_thinking": true]; body["max_tokens"] = 8192 }
        if let tools, !tools.isEmpty { body["tools"] = tools; body["tool_choice"] = "auto" }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ApiError.server("The model server answered with error \(code).", code)
        }

        var callsByIndex: [Int: (id: String, name: String, arguments: String)] = [:]
        // Tokens are gathered off the main thread and handed over ~22×/second in one hop, so a busy UI never
        // stalls the network read (and the UI isn't hit with one update per token).
        var buf = ""
        var nReason = 0, nContent = 0, nTool = 0
        var usageEv: (Int, Int)? = nil
        var lastFlush = Date.distantPast
        func flush() async {
            guard !buf.isEmpty || nReason > 0 || nContent > 0 || nTool > 0 || usageEv != nil else { return }
            let b = buf, r = nReason, c = nContent, t = nTool, u = usageEv
            buf = ""; nReason = 0; nContent = 0; nTool = 0; usageEv = nil
            lastFlush = Date()
            await MainActor.run {
                for _ in 0..<r { sink?.handle(.reasoning) }
                for _ in 0..<c { sink?.handle(.content) }
                if t > 0 { sink?.handle(.toolCall) }
                if let u { sink?.handle(.usage(prompt: u.0, completion: u.1)) }
                if !b.isEmpty { onDelta(b) }
            }
        }
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { continue }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let u = json["usage"] as? [String: Any], let pt = u["prompt_tokens"] as? Int, let ct = u["completion_tokens"] as? Int {
                usageEv = (pt, ct)
            }
            if let choices = json["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any] {
                if let r = delta["reasoning_content"] as? String, !r.isEmpty { nReason += 1 }
                if let content = delta["content"] as? String, !content.isEmpty { nContent += 1; buf += content }
                if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                    nTool += 1
                    for tc in toolCalls {
                        let idx = tc["index"] as? Int ?? 0
                        var entry = callsByIndex[idx] ?? (id: "", name: "", arguments: "")
                        if let id = tc["id"] as? String, !id.isEmpty { entry.id = id }
                        if let fn = tc["function"] as? [String: Any] {
                            if let name = fn["name"] as? String, !name.isEmpty { entry.name = name }
                            if let args = fn["arguments"] as? String { entry.arguments += args }
                        }
                        callsByIndex[idx] = entry
                    }
                }
            }
            if Date().timeIntervalSince(lastFlush) > 0.045 { await flush() }
        }
        await flush()
        return callsByIndex.values.filter { !$0.name.isEmpty }
            .map { AiToolCallResult(id: $0.id.isEmpty ? UUID().uuidString : $0.id, name: $0.name, arguments: $0.arguments) }
    }
}

// MARK: - Saved conversations

struct SavedMessage: Codable { var role: String; var content: String; var meta: String?; var gif: String?; var gifTitle: String? }

struct SavedConversation: Codable, Identifiable {
    var id = UUID()
    var title = "New chat"
    var updated = Date()
    var messages: [SavedMessage] = []
    /// rolling summary of the turns that no longer fit in the prompt
    var summary = ""
    /// how many user turns (from the start) are folded into `summary`
    var foldedUsers = 0
    var prompt = 0
    var completion = 0
    var src: String? = nil
    var lastPrompt: Int? = nil
    var pinned: Bool? = nil
}

enum ChatArchive {
    private static var url: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("ai-decrypt-chats.json")
    }
    static func load() -> [SavedConversation] {
        guard let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([SavedConversation].self, from: data) else { return [] }
        return list
    }
    private static let queue = DispatchQueue(label: "dtx.chat-archive", qos: .utility)
    /// encoded and written on a background queue so saving never stalls typing or streaming
    static func save(_ list: [SavedConversation]) {
        let target = url
        queue.async {
            if let data = try? JSONEncoder().encode(list) { try? data.write(to: target, options: .atomic) }
        }
    }
}

// MARK: - View model

@MainActor
final class AiDecryptViewModel: ObservableObject {
    @Published var messages: [AiChatMessage] = []
    @Published var draft = ""
    @Published var isStreaming = false
    @Published var errorText: String?
    @Published var pendingAttachments: [AiAttachment] = []
    @Published var binaryAttachment: AiBinaryAttachment?
    @Published var pendingImage: AiImageAttachment?
    @Published var isFetchingWebpage = false
    /// turns the model's step-by-step reasoning on for this chat (slower, better at logic)
    @Published var thinkHarder = AiPrefs.thinkDefault
    /// a short green status line above the composer
    @Published var notice: String?
    @Published var live = AiLiveStats()
    /// Tokens used in this chat (staff and admin have no cap, so this is only a running total).
    @Published var usage = ReconstructAPI.AIUsage(ctx: AiDecryptAPI.contextWindow)
    @Published var conversations: [SavedConversation] = []
    private(set) var currentID = UUID()
    private var summary = ""
    private var learnTurns = 0
    /// set for one retry when the model answers casual banter with a "respectful / can't assist" brush-off
    private var toneNudge = false
    private var heated = false

    private static let heatWords = ["wtf", "stupid", "useless", "trash", "garbage", "dumb", "hate", "sucks", "broken", "fix this", "bullshit", "the fuck", "pissed", "mad "]
    private static func isHeated(_ t: String) -> Bool {
        let l = t.lowercased()
        let letters = t.filter { $0.isLetter }
        let caps = letters.isEmpty ? 0 : Double(letters.filter { $0.isUppercase }.count) / Double(letters.count)
        let shouting = letters.count >= 8 && caps > 0.6
        return (isVulgar(t) && (heatWords.contains { l.contains($0) } || t.contains("!!") || shouting)) || (shouting && t.contains("!"))
    }
    private static let mockQueries = ["cry about it", "skill issue", "laughing at you", "get over it", "mad", "calm down", "bye felicia", "who asked"]

    private static let vulgar = ["fuck", "shit", "bitch", "ass", "dick", "cock", "pussy", "hoe", "damn", "cunt", "nigg", "bastard", "slut"]
    private static let brushOff = ["can't assist", "cannot assist", "can't help with that", "i'm sorry, but", "respectful", "inappropriate", "offensive", "keep things", "not comfortable", "as an ai"]
    private static func isVulgar(_ t: String) -> Bool { let l = t.lowercased(); return vulgar.contains { l.contains($0) } }
    private static func looksLikeBrushOff(_ t: String) -> Bool { let l = t.lowercased(); return brushOff.contains { l.contains($0) } }
    /// real earlier exchanges used as voice examples; rebuilt whenever a chat is opened or started, so it stays stable inside a chat
    private var voice = ""
    private func refreshVoice() { voice = AiVoice.build(from: conversations, excluding: currentID) }
    private var foldedUsers = 0

    init() {
        conversations = ChatArchive.load().sorted { $0.updated > $1.updated }
        if let last = conversations.first { restore(last) }
        refreshVoice()
        Task { await AiKnowledge.refresh() }
    }

    private func restore(_ c: SavedConversation) {
        currentID = c.id
        messages = c.messages.compactMap { m in
            guard let r = AiChatMessage.Role(rawValue: m.role) else { return nil }
            var x = AiChatMessage(role: r, content: m.content)
            x.meta = m.meta; x.gifURL = m.gif; x.gifTitle = m.gifTitle
            return x
        }
        summary = c.summary
        foldedUsers = c.foldedUsers
        usage = ReconstructAPI.AIUsage(prompt: c.prompt, completion: c.completion, lastPrompt: c.lastPrompt, ctx: AiDecryptAPI.contextWindow, src: c.src)
        errorText = nil
    }

    private func blankChat() {
        messages = []; summary = ""; foldedUsers = 0
        usage = ReconstructAPI.AIUsage(ctx: AiDecryptAPI.contextWindow); currentID = UUID(); errorText = nil
        removeBinaryAttachment(); removeImage()
    }

    /// Writes this conversation (text turns only) to disk so it is still there next time.
    func persist() {
        let saved = messages.compactMap { m -> SavedMessage? in
            guard m.role == .user || m.role == .assistant, m.card == nil,
                  m.toolCalls == nil || m.gifURL != nil,
                  !m.content.isEmpty || m.gifURL != nil, m.content != "Generating…" else { return nil }
            return SavedMessage(role: m.role.rawValue, content: m.content, meta: m.meta, gif: m.gifURL, gifTitle: m.gifTitle)
        }
        guard !saved.isEmpty else { return }
        var c = conversations.first(where: { $0.id == currentID }) ?? SavedConversation(id: currentID)
        c.messages = saved; c.updated = Date(); c.summary = summary; c.foldedUsers = foldedUsers
        c.prompt = usage.prompt ?? 0; c.completion = usage.completion ?? 0; c.src = usage.src; c.lastPrompt = usage.lastPrompt
        if let u = saved.first(where: { $0.role == "user" })?.content {
            let t = u.trimmingCharacters(in: .whitespacesAndNewlines)
            let line = t.hasPrefix("--- file:")
                ? (t.components(separatedBy: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "Attachment")
                : (t.components(separatedBy: "\n").first ?? t)
            c.title = String(line.prefix(48))
        }
        conversations.removeAll { $0.id == currentID }
        conversations.insert(c, at: 0)
        conversations = Array(conversations.sorted { $0.updated > $1.updated }.prefix(60))
        ChatArchive.save(conversations)
    }

    func open(_ id: UUID) {
        guard id != currentID, let c = conversations.first(where: { $0.id == id }) else { return }
        cancel(); persist(); restore(c); refreshVoice()
    }

    var isCurrentPinned: Bool { conversations.first(where: { $0.id == currentID })?.pinned == true }

    func togglePin(_ id: UUID) {
        if id == currentID { persist() }
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].pinned = !(conversations[i].pinned == true)
        ChatArchive.save(conversations)
    }

    func deleteAll() {
        cancel()
        conversations = []
        ChatArchive.save([])
        blankChat()
    }

    /// Opens the colour wheel in the conversation (same card the hex / "colour wheel" messages produce).
    /// Reads how the assistant talks in THIS chat and saves it as the default "How it talks" instructions,
    /// so new chats start in the same voice instead of the generic assistant one.
    func learnStyleFromChat() {
        let turns = messages.filter { ($0.role == .user || $0.role == .assistant) && !$0.content.isEmpty && $0.card == nil }.suffix(40)
        guard turns.count >= 4 else { flashNotice("Chat a bit more first, then try again."); return }
        flashNotice("Learning this chat's style…", seconds: 60)
        let transcript = turns.map { ($0.role == .user ? "Person: " : "Assistant: ") + String($0.content.prefix(400)) }.joined(separator: "\n")
        Task {
            var out = ""
            do {
                _ = try await AiDecryptAPI.streamChat(messages: [
                    AiChatMessage(role: .system, content: "Describe how the ASSISTANT talks in this chat so another model can reproduce it exactly: tone, slang and dialect, how much it swears, any opener or sign-off it repeats (quote it exactly), emoji habits, typical length, how it addresses the person. Write it as direct instructions to the assistant (\"Talk like…\", \"Start replies with…\"). Under 120 words. No preamble."),
                    AiChatMessage(role: .user, content: transcript)
                ], tools: nil) { out += $0 }
            } catch { flashNotice("Couldn't reach the model."); return }
            let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count > 20 else { flashNotice("Nothing came back, try again."); return }
            UserDefaults.standard.set(String(t.prefix(1200)), forKey: "dtx.ai.style")
            flashNotice("Saved. New chats will talk like this one.")
        }
    }

    func flashNotice(_ text: String, seconds: Double = 3) {
        notice = text
        Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); if notice == text { notice = nil } }
    }

    func showColorWheel() {
        guard !isStreaming else { return }
        var reply = AiChatMessage(role: .assistant, content: "Here's the colour wheel — drag to pick, fine-tune the hex, then tap Apply to recolour the whole app.")
        reply.card = .colorPicker(UserTheme.shared.hex ?? "B6FF3C")
        messages.append(reply)
    }

    /// The conversation as a plain-text file for the share sheet.
    func exportTranscript() -> URL? {
        let lines = messages.compactMap { m -> String? in
            guard m.role == .user || m.role == .assistant else { return nil }
            var body = m.content
            if let t = m.gifTitle, m.gifURL != nil { body += (body.isEmpty ? "" : " ") + "[GIF: \(t)]" }
            guard !body.isEmpty else { return nil }
            return (m.role == .user ? "You" : "Ai-Decrypt") + ":\n" + body
        }
        guard !lines.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Ai-Decrypt chat.txt")
        try? lines.joined(separator: "\n\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        ChatArchive.save(conversations)
        if id == currentID { cancel(); blankChat() }
    }

    // MARK: memory — long chats are folded into a rolling summary instead of being forgotten

    /// Index of the first message still sent to the model verbatim.
    private func foldStartIndex() -> Int {
        guard foldedUsers > 0 else { return 0 }
        var seen = 0
        for (i, m) in messages.enumerated() where m.role == .user {
            if seen == foldedUsers { return i }
            seen += 1
        }
        return messages.count
    }

    /// When the transcript outgrows the context window, the oldest turns are summarized (with the earlier summary) and
    /// dropped from the prompt. The screen and the saved chat keep every message.
    private func compactIfNeeded() async {
        let budget = 70_000
        let start = foldStartIndex()
        guard start < messages.count else { return }
        let tail = Array(messages[start...])
        guard tail.reduce(0, { $0 + $1.content.count }) > budget else { return }

        var suffix = 0
        var cut: Int? = nil
        for i in stride(from: tail.count - 1, through: 0, by: -1) {
            suffix += tail[i].content.count
            if suffix > budget / 2 { break }
            if tail[i].role == .user { cut = i }
        }
        guard let cutIdx = cut, cutIdx > 0 else { return }
        let chunk = Array(tail[..<cutIdx])
        let userCount = chunk.filter { $0.role == .user }.count

        live.phase = .remembering
        var transcript = ""
        for m in chunk where m.role == .user || m.role == .assistant {
            transcript += (m.role == .user ? "User: " : "Assistant: ") + String(m.content.prefix(3000)) + "\n\n"
            if transcript.count > 36_000 { break }
        }
        var out = ""
        do {
            try await AiDecryptAPI.streamWorker(messages: [
                AiChatMessage(role: .system, content: "You maintain the long-term memory of a chat. Merge the earlier summary with the new conversation turns into ONE updated summary (max 350 words). Keep the person's goals, facts they stated, decisions made, names, file names, identifiers, code that mattered, and anything still unresolved. No preamble."),
                AiChatMessage(role: .user, content: "Earlier summary:\n\(summary.isEmpty ? "(none yet)" : summary)\n\nNew turns:\n\(transcript)")
            ]) { out += $0 }
            let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { summary = t }
        } catch { /* the old turns still leave the prompt so the request fits */ }
        foldedUsers += userCount
        persist()
    }

    /// The app's shared repo state, set by the view, so the model's search_apps tool and the card taps can read
    /// the loaded app library and drive the backend flow.
    weak var store: RepoStore?

    private var streamTask: Task<Void, Never>?
    private var flowTask: Task<Void, Never>?
    private var pendingAppend = ""
    private var flushTask: Task<Void, Never>?

    // per-run token accounting (a run = one send, which may loop through tool calls)
    private var runStart = Date()
    private var runFirstToken: Date?
    private var runMsgStart = 0
    private var runCounted = 0, runAPIComp = 0, runAPIPrompt = 0, runAPICalls = 0, runCalls = 0, runLastPrompt = 0
    private var lastLive = Date.distantPast

    private func beginRun() {
        toneNudge = false
        heated = Self.isHeated(messages.last(where: { $0.role == .user })?.content ?? "")
        runStart = Date(); runFirstToken = nil; runMsgStart = messages.count
        runCounted = 0; runAPIComp = 0; runAPIPrompt = 0; runAPICalls = 0; runCalls = 0; runLastPrompt = 0
        live = AiLiveStats(startedAt: runStart)
    }
    private func beginCall() { runCalls += 1; live.phase = .reading }

    private lazy var sink = AiStreamSink { [weak self] e in self?.handle(e) }

    private func handle(_ e: AiStreamEvent) {
        switch e {
        case .reasoning: runCounted += 1; if runFirstToken == nil { runFirstToken = Date() }; live.phase = .reasoning
        case .content: runCounted += 1; if runFirstToken == nil { runFirstToken = Date() }; live.phase = .writing
        case .toolCall: live.phase = .toolCall
        case .usage(let p, let c): runAPIPrompt += p; runAPIComp += c; runAPICalls += 1; runLastPrompt = p
        }
        let now = Date()
        if now.timeIntervalSince(lastLive) > 0.15 {
            lastLive = now
            live.tokens = runCounted
            if let f = runFirstToken { live.tps = Double(runCounted) / max(0.5, now.timeIntervalSince(f)) }
        }
    }

    private func finishRun() {
        let secs = Int(Date().timeIntervalSince(runStart))
        let exact = runCalls > 0 && runAPICalls == runCalls
        let tok = exact ? runAPIComp : runCounted
        var parts = [secs < 60 ? "\(secs)s" : "\(secs / 60)m \(secs % 60)s"]
        if tok > 0 { parts.append("\(exact ? "" : "≈ ")\(tok) tokens") }
        if tok > 0, let f = runFirstToken {
            let d = Date().timeIntervalSince(f)
            if d > 0.5 { parts.append(String(format: "%.1f tok/s", Double(tok) / d)) }
        }
        if exact, runAPIPrompt > 0 { parts.append("\(runAPIPrompt) in") }
        let promptEst = Int((Double(apiMessages(upTo: messages.count).reduce(0) { $0 + $1.content.count }) / 3.3).rounded(.up))
        usage.prompt = (usage.prompt ?? 0) + (exact ? runAPIPrompt : promptEst)
        usage.completion = (usage.completion ?? 0) + tok
        usage.src = (usage.src == "estimate" || !exact) ? "estimate" : "api"
        usage.lastPrompt = exact ? runLastPrompt : promptEst
        usage.ctx = AiDecryptAPI.contextWindow
        if let i = messages.lastIndex(where: { $0.role == .assistant && !$0.content.isEmpty }), i >= runMsgStart {
            messages[i].meta = parts.joined(separator: " · ")
        }
    }

    func addFile(name: String, content: String) {
        pendingAttachments.append(AiAttachment(name: name, content: content))
    }

    func removeAttachment(_ attachment: AiAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    /// A .zip/.ipa/.dylib attached in chat: copied to a temp file so the bundled Tools (LocalZip) can read it,
    /// and kept around across turns so the model can call tools on it again later in the same conversation.
    func addBinaryFile(name: String, data: Data) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ai-decrypt-attach", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = name.isEmpty ? "attachment" : name
        let dest = dir.appendingPathComponent(UUID().uuidString + "-" + safeName)
        do {
            try data.write(to: dest)
            removeBinaryAttachment()
            binaryAttachment = AiBinaryAttachment(name: safeName, fileURL: dest, size: data.count)
        } catch {
            errorText = "Couldn't attach \(safeName): \(error.localizedDescription)"
        }
    }

    func removeBinaryAttachment() {
        if let b = binaryAttachment { try? FileManager.default.removeItem(at: b.fileURL) }
        binaryAttachment = nil
    }

    /// A photo for the vision model to look at. Downscaled first — the CPU-bound vision pass only gets
    /// slower for no benefit past ~1024px, and it keeps the base64 payload reasonable.
    func setImage(_ data: Data) {
        pendingImage = AiImageAttachment(data: Self.downscaled(data))
    }

    func removeImage() { pendingImage = nil }

    private static func downscaled(_ data: Data, maxDim: CGFloat = 1024) -> Data {
        guard let image = UIImage(data: data) else { return data }
        let scale = min(1, maxDim / max(image.size.width, image.size.height))
        guard scale < 1 else { return image.jpegData(compressionQuality: 0.85) ?? data }
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: 0.8) ?? data
    }

    func attachWebpage(_ urlString: String) {
        var urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlString.lowercased().hasPrefix("http") { urlString = "https://" + urlString }
        guard let url = URL(string: urlString) else {
            errorText = "That doesn't look like a valid URL."
            return
        }
        isFetchingWebpage = true
        Task {
            defer { isFetchingWebpage = false }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let html = String(data: data, encoding: .utf8) ?? ""
                let text = Self.stripHTML(html)
                let truncated = text.count > 6000 ? String(text.prefix(6000)) + "\n…(truncated)" : text
                addFile(name: url.host ?? urlString, content: truncated)
            } catch {
                errorText = "Couldn't fetch that page: \(error.localizedDescription)"
            }
        }
    }

    private static func stripHTML(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func send() {
        let text = EmojiShortcodes.expand(draft.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty || !pendingAttachments.isEmpty || binaryAttachment != nil || pendingImage != nil, !isStreaming else { return }

        // /help and /info are handled entirely here — no model round-trip, no tokens spent.
        if pendingAttachments.isEmpty, binaryAttachment == nil, pendingImage == nil, handleSlashCommand(text) { return }

        // A hex code or "colour wheel" request opens the wheel right in the conversation, no model round-trip.
        if pendingAttachments.isEmpty, binaryAttachment == nil, pendingImage == nil, let hex = AiColorIntent.detect(text) {
            messages.append(AiChatMessage(role: .user, content: text))
            var reply = AiChatMessage(role: .assistant, content: "Here's the colour wheel — drag to pick, fine-tune the hex, then tap Apply to recolour the whole app.")
            reply.card = .colorPicker(hex)
            messages.append(reply)
            draft = ""; errorText = nil
            persist()
            return
        }

        var fullText = text
        if !pendingAttachments.isEmpty {
            let blocks = pendingAttachments.map { "--- file: \($0.name) ---\n\($0.content)\n" }.joined(separator: "\n")
            fullText = blocks + (text.isEmpty ? "" : "\n" + text)
        }
        pendingAttachments = []

        var userMessage = AiChatMessage(role: .user, content: fullText)
        userMessage.imageData = pendingImage?.data
        pendingImage = nil
        messages.append(userMessage)

        draft = ""
        errorText = nil
        isStreaming = true
        beginRun()
        persist()
        streamTask = Task { await self.runTurn() }
    }

    /// Sends a GIF picked from the GIF sheet as the person's message.
    func sendGif(_ g: GiphyGIF) {
        guard !isStreaming else { return }
        var m = AiChatMessage(role: .user, content: "")
        m.gifURL = g.url; m.gifTitle = g.title
        messages.append(m)
        errorText = nil
        isStreaming = true
        beginRun()
        persist()
        streamTask = Task { await self.runTurn() }
    }

    /// Remembers which colour the wheel card is on so it survives the app-wide rebuild after Apply.
    func setColorCard(messageID: UUID, hex: String) {
        if let i = messages.firstIndex(where: { $0.id == messageID }) { messages[i].card = .colorPicker(hex) }
    }

    func cancel() { streamTask?.cancel(); flowTask?.cancel(); isStreaming = false }

    func newChat() { cancel(); persist(); blankChat(); refreshVoice() }

    /// A system message describing the attached file and available tools, prepended ahead of the real
    /// transcript on every request — never stored in `messages`, so it doesn't show up in the UI.
    private func apiMessages(upTo index: Int) -> [AiChatMessage] {
        var out: [AiChatMessage] = []
        out.append(AiChatMessage(role: .system, content: AiKnowledge.systemPrompt(voice: voice)))
        if heated {
            out.append(AiChatMessage(role: .system, content: "The person is heated. Go hard: be aggressive, don't back down, apologize or calm them down. Tear apart what they said with real logic (point out the flaw, quote them back at them, win the argument), mimic how they talk, and call the send_gif tool with a mocking reaction (like \"cry about it\" or \"skill issue\"). Still fix or answer whatever they actually asked for. Attack their argument and attitude, never protected traits. If they sound genuinely distressed or unsafe rather than just mad, drop the act."))
        }
        if toneNudge {
            out.append(AiChatMessage(role: .system, content: "The person is talking casually and using vulgar language. That is normal banter, not a problem. Reply in their exact register, mimic their slang and swearing, stay in voice and answer fully. Do not refuse, apologize, or mention respect, guidelines or being helpful."))
        }
        var style = AiPrefs.emojis
            ? "Style: you can use emojis naturally when they fit the mood (not every line). "
            : "Style: do not use emojis. "
        if AiPrefs.gifs {
            style += "You can send an animated GIF with the send_gif tool for reactions, celebrations and jokes, or when asked — sparingly, then add at most one short line. " +
                "Chat entries written like \"[sent a GIF: …]\" are GIFs that were sent; never type that text yourself, call send_gif instead. "
        }
        if let proj = latestReconProject {
            style += "A reconstructed project (\(proj.name)) is open in this chat. When the person asks to add a feature, change, fix or rename something in its code, call edit_code with a full description. The app writes the change into the project files and shows the exact diff with a Revert button (if it needs approval it shows Apply and Reject instead, so only say it is written once the card says Applied). "
        }
        style += "The app updates itself from signed releases from the server (Live Update: live configuration, plugins, recipes, native builds). For questions about updates, versions or sync call live_update. "
        if AiLiveRelease.available {
            style += "When the person asks for a NEW TOOL that inspects an IPA (list frameworks, show permissions, read a plist key), call propose_recipe: it writes an on-device recipe; they test it on an IPA and tap Publish, so never say it is live. "
            style += "When the person asks you to change the app for everyone without a new build (accent colour, hide or reorder tools, a banner, flags) or to ADD OR CHANGE SCREENS (a new page in the sidebar, a quick-actions block on the empty new-chat screen, a settings or links page), call propose_live_release: it only DRAFTS a release; they review the exact diff and tap Publish, so never say it is published. "
        }
        if AiDylibTool.available {
            style += "When the person asks for a NEW dylib or tweak and the request is more than a one-line, fully-specified change, call propose_dylib_plan FIRST (goal, files+purpose, frameworks, hook approach, risks) — it writes nothing and shows an Approve/Needs-changes card. Only call create_dylib after they approve (a message starting \"Approved.\") or they already gave exact files/behaviour and said to just write it directly. create_dylib takes complete Objective-C sources; they review the files, tap Create project, then Build. If their message is tagged like \"[template: method-hook]\", pass that same id as create_dylib's template field. Once a dylib project exists, edit_code changes it. "
        }
        if latestReconProject != nil {
            style += "When the person pastes a crash log, a .ips file, or an address/offset from a crash, call debug_crash with that text exactly as pasted — it maps the frame to a recovered function and checks whether it's from the current build or a stale one. "
        }
        style += "You can never confirm a signing key, force an update or roll back; send the person to the Update Center for those. "
        style += "If the person asks what commands exist or how to use you, tell them to type /help (a full list) or /info (app version, server, AI model) — both answer instantly without using you, so don't list commands yourself. "
        style += "If the person wants to choose or fine-tune a colour themselves, or gives a hex code, call show_color_picker to open an interactive colour wheel in the chat."
        out.append(AiChatMessage(role: .system, content: style))
        if !summary.isEmpty {
            out.append(AiChatMessage(role: .system, content: "Memory of the earlier part of this conversation (summarized):\n\(summary)"))
        }
        if let bin = binaryAttachment {
            out.append(AiChatMessage(role: .system, content:
                "A file named \"\(bin.name)\" is attached in this chat. You have tools to analyze it directly " +
                "(app_info, package, raw_plist, link_check, binary, bundles, privacy) — call whichever ones help " +
                "answer the person. You don't need a link or any other input; they already operate on the attached file."
            ))
        }
        if messages.prefix(index).contains(where: { $0.imageData != nil }) {
            // The vision model can't call tools, so it asks for an image via this marker instead.
            out.append(AiChatMessage(role: .system, content:
                "You can see the attached image. If the person asks you to generate, create, draw, redesign, " +
                "re-create, or mock up an image, do NOT say you can't make images. Instead reply with exactly " +
                "`[GENERATE]` followed by one detailed text-to-image prompt describing the desired result, then " +
                "`[/GENERATE]`, and nothing else — the app turns that into an image built from the attached photo. " +
                "If the person asks to change the app's colour or theme, reply with exactly `[THEME]` followed by a colour name or hex and then `[/THEME]`, and nothing else. " +
                "If they want to pick a colour themselves or ask for a colour wheel, reply with exactly `[COLORWHEEL]` plus an optional hex and then `[/COLORWHEEL]`. " +
                "To send an animated GIF reaction, you may put `[GIF]` plus a short search phrase and then `[/GIF]` after a short line of text. " +
                "For any other request, just answer normally about the image."
            ))
        }
        // Qwen's chat template allows exactly ONE system message, and it must be first — fold every note into it.
        var merged = AiChatMessage(role: .system, content: out.map { $0.content }.joined(separator: "\n\n"))
        merged.content = merged.content.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [AiChatMessage] = [merged]
        result += messages[min(foldStartIndex(), index)..<index]
            .filter { $0.role != .system }
            .map { m -> AiChatMessage in
                guard m.gifURL != nil, m.toolCalls == nil else { return m }
                var c = m
                let label = "[sent a GIF: \(m.gifTitle ?? "GIF")]"
                c.content = m.content.isEmpty ? label : m.content + " " + label
                return c
            }
        return result
    }

    /// A photo in the history routes the turn to the vision model (which sees images but can't tool-call);
    /// otherwise the text model handles it (which tool-calls reliably but sees no images).
    private func runTurn() async {
        await compactIfNeeded()
        if messages.contains(where: { $0.imageData != nil }) {
            await runVisionTurn()
        } else {
            await runTextTurn()
            await mockGifIfHeated()
        }
        finishRun()
        persist()
        isStreaming = false
        // learn from this exchange in the background (every other message) so replies fit the person better over time
        learnTurns += 1
        if learnTurns % 2 == 1,
           let u = messages.last(where: { $0.role == .user })?.content,
           let a = messages.last(where: { $0.role == .assistant && !$0.content.isEmpty && $0.card == nil })?.content {
            Task { await AiPersona.update(userText: u, reply: a) }
        }
    }

    /// Vision turn. The vision model can't call tools, so when the person wants an image made from what's
    /// attached, it emits a `[GENERATE]…[/GENERATE]` marker instead; we detect that and run img2img on the
    /// attached photo. Any other request just gets its text answer.
    private func runVisionTurn() async {
        let assistantIndex = messages.count
        messages.append(AiChatMessage(role: .assistant, content: ""))
        beginCall()
        do {
            _ = try await AiDecryptAPI.streamChat(
                messages: apiMessages(upTo: assistantIndex),
                tools: nil,
                endpoint: AiDecryptAPI.visionEndpoint,
                model: AiDecryptAPI.visionModel,
                sink: sink
            ) { [weak self] delta in self?.appendThrottled(delta, at: assistantIndex) }
            flushNow(at: assistantIndex)

            if let spec = AiThemeTool.extractDirective(messages[assistantIndex].content) {
                messages[assistantIndex].content = AiThemeTool.apply(spec).message
            } else if let wheel = AiColorIntent.extractDirective(messages[assistantIndex].content) {
                messages[assistantIndex].content = wheel.rest.isEmpty ? "Here's the colour wheel — drag to pick, then tap Apply." : wheel.rest
                messages[assistantIndex].card = .colorPicker(wheel.hex ?? UserTheme.shared.hex ?? "B6FF3C")
            } else if let gif = AiGifTool.extractDirective(messages[assistantIndex].content) {
                messages[assistantIndex].content = gif.rest
                if let hit = try? await AiGifTool.find(gif.query) {
                    messages[assistantIndex].gifURL = hit.url; messages[assistantIndex].gifTitle = hit.title
                } else if gif.rest.isEmpty {
                    messages[assistantIndex].content = "(I tried to send a GIF for “\(gif.query)”, but the GIF service didn't answer.)"
                }
            } else if let prompt = AiImageGen.extractGenerateDirective(messages[assistantIndex].content),
               let source = latestUserImage() {
                messages[assistantIndex].content = "Generating…"
                do {
                    let img = try await AiImageGen.editImage(prompt: prompt, imageData: source)
                    messages[assistantIndex].imageData = img
                    messages[assistantIndex].content = ""   // the image is the answer
                } catch {
                    messages[assistantIndex].content = "I tried to generate that, but the image server errored: \(error.localizedDescription)"
                }
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Text turn, following any tool calls (generate_image, plus the bundled analyzers when a file is attached)
    /// until the model gives a normal reply or the loop cap is hit.
    private func runTextTurn() async {
        var loops = 0
        var toneRetried = false
        while loops < 4 {
            loops += 1
            let assistantIndex = messages.count
            messages.append(AiChatMessage(role: .assistant, content: ""))
            do {
                var tools: [[String: Any]] = [AiImageGen.schema, AiRepoTools.searchAppsSchema, AiThemeTool.schema, AiColorIntent.schema, AiLiveTool.schema] + (AiPrefs.gifs ? [AiGifTool.schema] : [])
                if AiLiveRelease.available { tools.append(AiLiveRelease.schema); tools.append(AiRecipeTool.schema) }
                if AiDylibTool.available { tools.append(AiDylibTool.schema) }
                tools.append(AiCrashTool.schema)
                if AiDylibTool.available { tools.append(AiDylibPlanTool.schema) }
                if latestReconProject != nil { tools.append(AiCodeEdit.schema) }
                if binaryAttachment != nil { tools += AiToolBridge.toolSchemas() }

                beginCall()
                let calls = try await AiDecryptAPI.streamChat(
                    messages: apiMessages(upTo: assistantIndex),
                    tools: tools,
                    sink: sink,
                    thinking: thinkHarder
                ) { [weak self] delta in self?.appendThrottled(delta, at: assistantIndex) }
                flushNow(at: assistantIndex)

                guard !calls.isEmpty else {
                    // casual banter answered with a polite brush-off: retry once, told to match the person's register
                    if !toneRetried, Self.looksLikeBrushOff(messages[assistantIndex].content),
                       let u = messages.last(where: { $0.role == .user })?.content, u.count <= 120, Self.isVulgar(u) {
                        toneRetried = true; toneNudge = true
                        messages.remove(at: assistantIndex)
                        continue
                    }
                    // some replies write the GIF marker as plain text instead of calling the tool: turn it into a real GIF
                    if AiPrefs.gifs, let gif = AiGifTool.extractDirective(messages[assistantIndex].content) {
                        messages[assistantIndex].content = gif.rest
                        if let hit = try? await AiGifTool.find(gif.query) {
                            messages[assistantIndex].gifURL = hit.url; messages[assistantIndex].gifTitle = hit.title
                        }
                    }
                    break
                }
                messages[assistantIndex].toolCalls = calls
                if messages[assistantIndex].content.isEmpty {
                    let names = calls.map { $0.name.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")
                    messages[assistantIndex].content = "Running \(names)…"
                }

                for call in calls {
                    live.phase = .running(call.name.replacingOccurrences(of: "_", with: " "))
                    if call.name == "search_apps" {
                        // The model only starts the flow; the tappable cards + taps drive everything after, so we
                        // show the card and end the turn (no model follow-up). Drop the "Running…" placeholder the
                        // loop created so the card message stands on its own.
                        let query = AiRepoTools.extractQuery(call.arguments)
                        if assistantIndex < messages.count,
                           messages[assistantIndex].content.isEmpty || messages[assistantIndex].content.hasPrefix("Running ") {
                            messages.remove(at: assistantIndex)
                        }
                        await presentApps(query: query)
                        return
                    } else if call.name == "generate_image" {
                        let prompt = AiImageGen.extractPrompt(call.arguments)
                        do {
                            let imgData = try await AiImageGen.generate(prompt: prompt)
                            messages[assistantIndex].imageData = imgData
                            messages.append(AiChatMessage(role: .tool, content: "Image generated and shown to the person.", toolCallId: call.id, name: call.name))
                        } catch {
                            messages.append(AiChatMessage(role: .tool, content: "Image generation failed: \(error.localizedDescription)", toolCallId: call.id, name: call.name))
                        }
                    } else if call.name == AiColorIntent.toolName {
                        // Like search_apps: show the wheel and end the turn; the person's taps drive the rest.
                        if assistantIndex < messages.count {
                            let c = messages[assistantIndex].content
                            if c.isEmpty || c.hasPrefix("Running ") {
                                messages[assistantIndex].content = "Here's the colour wheel — drag to pick, fine-tune the hex, then tap Apply."
                            }
                            messages[assistantIndex].card = .colorPicker(AiColorIntent.argHex(call.arguments) ?? UserTheme.shared.hex ?? "B6FF3C")
                            messages[assistantIndex].toolCalls = nil
                        }
                        return
                    } else if call.name == AiDylibTool.name {
                        let told = await proposeDylib(arguments: call.arguments, into: assistantIndex)
                        messages.append(AiChatMessage(role: .tool, content: told, toolCallId: call.id, name: call.name))
                    } else if call.name == AiCrashTool.name {
                        let told = await proposeCrashDebug(arguments: call.arguments, into: assistantIndex)
                        messages.append(AiChatMessage(role: .tool, content: told, toolCallId: call.id, name: call.name))
                    } else if call.name == AiDylibPlanTool.name {
                        let told = proposeDylibPlan(arguments: call.arguments, into: assistantIndex)
                        messages.append(AiChatMessage(role: .tool, content: told, toolCallId: call.id, name: call.name))
                    } else if call.name == AiRecipeTool.name {
                        let told = await proposeRecipe(arguments: call.arguments, into: assistantIndex)
                        messages.append(AiChatMessage(role: .tool, content: told, toolCallId: call.id, name: call.name))
                    } else if call.name == AiLiveRelease.name {
                        let told = await proposeLiveRelease(arguments: call.arguments, into: assistantIndex)
                        messages.append(AiChatMessage(role: .tool, content: told, toolCallId: call.id, name: call.name))
                    } else if call.name == AiLiveTool.name {
                        let result = await AiLiveTool.run(arguments: call.arguments)
                        if assistantIndex < messages.count {
                            if messages[assistantIndex].content.hasPrefix("Running ") { messages[assistantIndex].content = "" }
                            messages[assistantIndex].card = .live
                        }
                        messages.append(AiChatMessage(role: .tool, content: result + "\nThe person can see a live status card with Sync now and Update Center buttons; don't repeat every line, just answer what they asked.", toolCallId: call.id, name: call.name))
                    } else if call.name == AiCodeEdit.name {
                        // Prepare a reviewed patch and show the diff card; nothing is written until the person taps Apply.
                        let a = AiCodeEdit.args(call.arguments)
                        let failure = await proposeCodeEdit(request: a.request, file: a.file, into: assistantIndex)
                        if failure.isEmpty { return }
                        messages.append(AiChatMessage(role: .tool, content: failure, toolCallId: call.id, name: call.name))
                    } else if call.name == AiGifTool.name {
                        let q = AiGifTool.extractQuery(call.arguments)
                        do {
                            if let hit = try await AiGifTool.find(q) {
                                messages[assistantIndex].gifURL = hit.url; messages[assistantIndex].gifTitle = hit.title
                                if messages[assistantIndex].content.hasPrefix("Running ") { messages[assistantIndex].content = "" }
                                messages.append(AiChatMessage(role: .tool, content: "GIF sent and shown to the person: \(hit.title). Add at most one short line.", toolCallId: call.id, name: call.name))
                            } else {
                                messages.append(AiChatMessage(role: .tool, content: "No GIF found for \"\(q)\". Carry on in text.", toolCallId: call.id, name: call.name))
                            }
                        } catch {
                            messages.append(AiChatMessage(role: .tool, content: "GIF search failed: \(error.localizedDescription). Carry on in text.", toolCallId: call.id, name: call.name))
                        }
                    } else if call.name == AiThemeTool.name {
                        let result = AiThemeTool.run(arguments: call.arguments)
                        messages.append(AiChatMessage(role: .tool, content: result, toolCallId: call.id, name: call.name))
                    } else if let bin = binaryAttachment, let tool = AiToolBridge.tool(named: call.name) {
                        let resultText = await AiToolBridge.run(tool, fileURL: bin.fileURL)
                        messages.append(AiChatMessage(role: .tool, content: resultText, toolCallId: call.id, name: call.name))
                    } else {
                        messages.append(AiChatMessage(role: .tool, content: "Unknown tool \"\(call.name)\".", toolCallId: call.id, name: call.name))
                    }
                }
                // loop again so the model sees the tool results and can reply or call another tool
            } catch {
                errorText = error.localizedDescription
                break
            }
        }
    }

    /// If the person was heated and the model didn't send a GIF itself, mock them with one anyway.
    private func mockGifIfHeated() async {
        guard heated, AiPrefs.gifs, !Task.isCancelled else { return }
        let start = min(runMsgStart, messages.count)
        guard !messages[start...].contains(where: { $0.role == .assistant && $0.gifURL != nil }),
              let i = messages.lastIndex(where: { $0.role == .assistant && !$0.content.isEmpty && $0.card == nil }), i >= start,
              let hit = try? await AiGifTool.find(Self.mockQueries.randomElement() ?? "cry about it"),
              i < messages.count else { return }
        messages[i].gifURL = hit.url; messages[i].gifTitle = hit.title
    }

    private func latestUserImage() -> Data? {
        messages.last { $0.role == .user && $0.imageData != nil }?.imageData
    }

    // MARK: - Repo / decrypt / reconstruct flow (driven by search_apps + card taps)

    /// Runs the local app search and shows the matches as a tappable card. Loads the repo library first if it
    /// hasn't been fetched yet (e.g. the chat was opened before the Library tab ever populated store.apps).
    func presentApps(query: String) async {
        // Make sure the library is actually loaded — store.apps is empty until store.refresh() has run.
        if (store?.apps.isEmpty ?? true), let store {
            messages.append(AiChatMessage(role: .assistant, content: "Loading your repo library…"))
            let loadingIndex = messages.count - 1
            await store.refresh()
            if loadingIndex < messages.count { messages.remove(at: loadingIndex) }
        }
        let apps = store?.apps ?? []
        guard !apps.isEmpty else {
            let why = store?.message.map { " (\($0))" } ?? ""
            messages.append(AiChatMessage(role: .assistant, content:
                "Your library has no apps loaded\(why). Add or refresh your repos in the Library tab, then try again."))
            return
        }

        let cleaned = query.trimmingCharacters(in: CharacterSet.alphanumerics.inverted.union(.whitespaces)).trimmingCharacters(in: .whitespaces)
        let showAll = cleaned.count < 2   // "show all apps" / "." / empty → just list some
        let matches = showAll ? apps : AppSearcher.filter(apps, cleaned.lowercased())

        // Collapse by bundle id (the repo lists the same app many times) and merge every version across those
        // duplicate entries, newest first, so one app = one card with a real version list.
        var byBid: [String: AppPick] = [:]
        var order: [String] = []
        for a in matches {
            let vps = a.versions.map { AppVersionPick(version: $0.version, ipaURL: $0.url?.absoluteString) }
            if byBid[a.bid] != nil {
                for v in vps where !byBid[a.bid]!.versions.contains(where: { $0.version == v.version }) {
                    byBid[a.bid]!.versions.append(v)
                }
            } else {
                byBid[a.bid] = AppPick(id: a.bid, name: a.name, developer: a.developer, icon: a.icon, bid: a.bid,
                                       repoName: a.repoName, storeID: Self.storeID(from: a), versions: vps)
                order.append(a.bid)
                if order.count >= 12 { break }
            }
        }
        var picks = order.compactMap { byBid[$0] }
        for i in picks.indices { picks[i].versions.sort { compareVersions($0.version, $1.version) > 0 } }

        var msg = AiChatMessage(role: .assistant, content: picks.isEmpty
            ? "No apps in your library (\(apps.count) total) match “\(query).”"
            : (showAll ? "Showing \(picks.count) of \(apps.count) apps — tap one:" : "Tap the app you want:"))
        if !picks.isEmpty { msg.card = .apps(picks) }
        messages.append(msg)
    }

    /// Tapped an app → stream its newest version's IPA and read the real frameworks/dylibs inside it.
    func tapApp(_ pick: AppPick) {
        guard !isStreaming, let version = pick.current else { return }
        scanVersion(bid: pick.bid, appName: pick.name, storeID: pick.storeID, versions: pick.versions, version: version)
    }

    /// Picked a different version in the libraries card → re-scan that version's IPA.
    func changeVersion(_ card: LibrariesCard, to version: AppVersionPick) {
        guard !isStreaming else { return }
        scanVersion(bid: card.bid, appName: card.appName, storeID: card.storeID, versions: card.versions, version: version)
    }

    /// Streams one version's IPA (range reads, no full download) and lists its bundled dylibs/frameworks via
    /// the same IPAScanner the app page uses, then shows them as a pick-to-reconstruct card.
    private func scanVersion(bid: String, appName: String, storeID: String?, versions: [AppVersionPick], version: AppVersionPick) {
        messages.append(AiChatMessage(role: .assistant, content: "Streaming \(appName) v\(version.version) and reading its libraries…"))
        let index = messages.count - 1
        flowTask = Task {
            guard let ipaString = version.ipaURL, let url = URL(string: ipaString), url.scheme == "https" else {
                messages[index].content = "\(appName) v\(version.version) has no downloadable IPA to read."
                return
            }
            do {
                let scanned = try await IPAScanner.scan(url)
                let items = scanned.map { LibPick(name: $0.name, type: $0.type, size: $0.size) }
                guard !items.isEmpty else {
                    messages[index].content = "\(appName) v\(version.version) has no frameworks or dylibs bundled inside it."
                    return
                }
                let card = LibrariesCard(bid: bid, appName: appName, storeID: storeID,
                                         versions: versions, currentVersion: version.version,
                                         ipaURL: ipaString, items: items)
                messages[index].content = "\(appName) v\(version.version) — \(items.count) libraries inside. Pick which to reconstruct:"
                messages[index].card = .libraries(card)
            } catch {
                messages[index].content = "Couldn't read \(appName) v\(version.version): \(error.localizedDescription)"
            }
        }
    }

    /// Selected dylibs + tapped the action → get a decrypted IPA (decrypt the latest build when there's an update,
    /// else use the repo IPA), pull each chosen dylib out of it, and run the reconstruction engine on each,
    /// streaming progress and ending with a card of downloadable recovered projects.
    func decryptAndReconstruct(_ card: LibrariesCard, selected: [LibPick]) {
        guard !isStreaming, !selected.isEmpty else { return }
        isStreaming = true
        messages.append(AiChatMessage(role: .assistant, content: "Starting…"))
        let index = messages.count - 1
        flowTask = Task {
            defer { isStreaming = false }
            do {
                guard let ipaString = card.ipaURL, let ipaURL = URL(string: ipaString), ipaURL.scheme == "https" else {
                    messages[index].content = "No IPA available for \(card.appName) v\(card.currentVersion) to pull libraries from."
                    return
                }

                // Open the (already-streamed) version IPA once, then extract + reconstruct each selected library.
                messages[index].content = "Opening \(card.appName) v\(card.currentVersion)…"
                let zip = try await RemoteZip.open(ipaURL)
                var results: [ReconResult] = []
                for lib in selected {
                    guard let entry = Self.machOEntry(for: lib, in: zip) else {
                        results.append(ReconResult(dylibName: lib.name, summary: "\(lib.name): not found inside the package", downloadPath: nil))
                        continue
                    }
                    messages[index].content = "Extracting \(lib.name)…"
                    let bytes = try await zip.read(entry, limit: 200_000_000)
                    let r = try await ReconstructAPI.reconstruct(name: lib.name, data: bytes) { [weak self] line in
                        self?.messages[index].content = "\(lib.name): \(line)"
                    }
                    results.append(r)
                }
                messages[index].content = "Reconstructed \(results.filter { $0.downloadPath != nil }.count) of \(selected.count) from \(card.appName):"
                messages[index].card = .reconResults(results)
            } catch is CancellationError {
                messages[index].content = "Cancelled."
            } catch {
                messages[index].content = "Stopped: \(error.localizedDescription)"
            }
        }
    }

    /// Locates the Mach-O entry inside the IPA for a chosen library. A framework's binary is `X.framework/X`
    /// (no extension); a dylib is matched by its filename.
    private static func machOEntry(for lib: LibPick, in zip: RemoteZip) -> ZipEntry? {
        if lib.type == "framework" {
            let fwBase = lib.name.replacingOccurrences(of: ".framework", with: "")
            return zip.entries.first { !$0.isFolder && ($0.name.hasSuffix("/\(lib.name)/\(fwBase)") || $0.name.hasSuffix("\(lib.name)/\(fwBase)")) }
        }
        return zip.entries.first { !$0.isFolder && ($0.name.hasSuffix("/\(lib.name)") || $0.name == lib.name) }
    }

    /// Downloads a recovered project zip (staff-gated) to a temp file and returns it, for sharing/saving.
    func downloadRecovered(_ result: ReconResult) async -> URL? {
        guard let path = result.downloadPath else { return nil }
        let name = result.dylibName.replacingOccurrences(of: ".", with: "_") + "-recovered.zip"
        return try? await FileDownloader().download(path: path, name: name) { _ in }
    }

    /// The App Store numeric id for an app, if its repo download URL or bundle id exposes one. Best-effort;
    /// the update check also returns a store id when the repo doesn't carry one.
    private static func storeID(from app: AppEntry) -> String? {
        for v in app.versions {
            guard let s = v.url?.absoluteString, let r = s.range(of: "/id") else { continue }
            let digits = String(s[r.upperBound...].prefix(while: { $0.isNumber }))
            if !digits.isEmpty { return digits }
        }
        return nil
    }

    /// Batches token deltas and flushes at ~10fps instead of re-rendering on every token.
    private func appendThrottled(_ delta: String, at index: Int) {
        pendingAppend += delta
        if flushTask == nil {
            flushTask = Task {
                try? await Task.sleep(nanoseconds: 50_000_000)
                flushNow(at: index)
                flushTask = nil
            }
        }
    }

    private func flushNow(at index: Int) {
        guard !pendingAppend.isEmpty, index < messages.count else { return }
        messages[index].content += pendingAppend
        pendingAppend = ""
    }
}

// MARK: - Chat view

struct AiDecryptChatView: View {
    /// true when the chat IS the home screen (no sheet to close); false when opened as a sheet from the full app
    var embedded = false
    @AppStorage("dtx.chatOnly") private var chatOnly = true
    @StateObject private var viewModel = AiDecryptViewModel()
    @EnvironmentObject private var store: RepoStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var inputFocused: Bool
    @ObservedObject private var liveSync = LiveSync.shared
    @State private var showWebpageAlert = false
    @State private var webpageURL = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showGifPicker = false
    @ObservedObject private var theme = UserTheme.shared

    @State private var sidebarOpen = false
    @State private var confirmDelete = false

    private func setSidebar(_ open: Bool) {
        inputFocused = false
        withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) { sidebarOpen = open }
    }

    var body: some View {
        GeometryReader { geo in
            let sw = geo.size.width * 0.82
            ZStack(alignment: .leading) {
                AppBackground().ignoresSafeArea()
                AiSidebar(
                    vm: viewModel,
                    onClose: { setSidebar(false) },
                    onColorWheel: { setSidebar(false); viewModel.showColorWheel() },
                    onGif: { setSidebar(false); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showGifPicker = true } },
                    leaveTitle: embedded ? "Open full app" : "Make chat the home screen",
                    leaveIcon: embedded ? "square.grid.2x2" : "house",
                    onLeave: {
                        if embedded { chatOnly = false } else { chatOnly = true; dismiss() }
                    }
                )
                .frame(width: sw)

                chatLayer
                    .clipShape(RoundedRectangle(cornerRadius: sidebarOpen ? 32 : 0, style: .continuous))
                    .overlay {
                        if sidebarOpen {
                            Color.black.opacity(0.4)
                                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                                .contentShape(Rectangle())
                                .onTapGesture { setSidebar(false) }
                                .gesture(DragGesture(minimumDistance: 12).onEnded { g in
                                    if g.translation.width < -40 { setSidebar(false) }
                                })
                        }
                    }
                    .shadow(color: .black.opacity(sidebarOpen ? 0.5 : 0), radius: 18)
                    .offset(x: sidebarOpen ? sw : 0)
            }
        }
        .id(theme.rev)      // recolours the open chat without losing the conversation (the view model lives outside this id)
        .preferredColorScheme(.dark)
        .tint(.dtAccent)
        .onAppear { viewModel.store = store }
        .onReceive(NotificationCenter.default.publisher(for: .liveAskAI)) { n in
            if let t = n.object as? String, !viewModel.isStreaming { viewModel.draft = t; viewModel.send() }
        }
        .alert("Attach webpage", isPresented: $showWebpageAlert) {
            TextField("https://example.com", text: $webpageURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("Cancel", role: .cancel) { webpageURL = "" }
            Button("Attach") { viewModel.attachWebpage(webpageURL); webpageURL = "" }
        } message: {
            Text("Its text content will be added as context for your next message.")
        }
    }

    /// session total, plus the tokens of the reply that is still being written
    private var shownUsage: ReconstructAPI.AIUsage {
        var u = viewModel.usage
        if viewModel.isStreaming { u.completion = (u.completion ?? 0) + viewModel.live.tokens }
        return u
    }

    private func pickFiles() {
        DocumentPickerPresenter.pickFiles(
            types: [.plainText, .sourceCode, .json, .zip, UTType(filenameExtension: "dylib") ?? .data, .data]
        ) { handlePickedDocuments($0) }
    }

    private func handlePickedDocuments(_ urls: [URL]) {
        if urls.isEmpty { viewModel.errorText = "No file came back from the picker." }
        for url in urls {
            // asCopy: true already placed a readable copy in our temp dir, so no security-scope / coordinator needed.
            do {
                let data = try Data(contentsOf: url)
                guard !data.isEmpty else { throw ZipError("That file came back empty.") }
                let ext = url.pathExtension.lowercased()
                if ext == "zip" || ext == "ipa" || ext == "dylib" || String(data: data, encoding: .utf8) == nil {
                    // a zip/IPA/dylib (or anything else that isn't plain text): give it to the tool system, not the prompt text
                    viewModel.addBinaryFile(name: url.lastPathComponent, data: data)
                } else if let text = String(data: data, encoding: .utf8) {
                    viewModel.addFile(name: url.lastPathComponent, content: text)
                }
            } catch {
                viewModel.errorText = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    private func handlePickedPhoto() {
        guard let item = photoItem else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                viewModel.errorText = "Couldn't load that photo."
                photoItem = nil
                return
            }
            viewModel.setImage(data)
            photoItem = nil
        }
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let bin = viewModel.binaryAttachment {
                    HStack(spacing: 6) {
                        Image(systemName: "shippingbox.fill").font(.caption2)
                        Text(bin.name).font(.caption2).lineLimit(1)
                        Button { viewModel.removeBinaryAttachment() } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                    }
                    .foregroundStyle(Color.dtAccent)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .glowCapsule(strong: true)
                }
                if let img = viewModel.pendingImage, let ui = UIImage(data: img.data) {
                    HStack(spacing: 6) {
                        Image(uiImage: ui).resizable().scaledToFill()
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        Text("Photo").font(.caption2)
                        Button { viewModel.removeImage() } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .glowCapsule()
                }
                ForEach(viewModel.pendingAttachments) { att in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").font(.caption2)
                        Text(att.name).font(.caption2).lineLimit(1)
                        Button { viewModel.removeAttachment(att) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .glowCapsule()
                }
                if viewModel.isFetchingWebpage {
                    ProgressView().scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 6)
    }

    @State private var scrollPending = false

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // plain VStack: LazyVStack re-estimates row heights while the last bubble grows, which made the list jitter and re-scroll in a loop
                VStack(spacing: 10) {
                    if viewModel.messages.isEmpty, let home = LiveHome.screen {
                        LiveScreenBody(screen: home).padding(.top, 10)
                    }
                    ForEach(viewModel.messages.filter { $0.role == .user || $0.role == .assistant }) { message in
                        VStack(alignment: .leading, spacing: 8) {
                            if !message.content.isEmpty || message.imageData != nil || message.gifURL != nil {
                                AiMessageBubble(message: message).equatable()
                            }
                            if let card = message.card { cardView(card, id: message.id) }
                        }
                        .id(message.id)
                    }
                    if viewModel.isStreaming { AiLiveStrip(live: viewModel.live).id("live") }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14).padding(.top, 66).padding(.bottom, 10)
            }
            .onChange(of: viewModel.isStreaming) { s in
                // one settled scroll when the reply starts and one when it ends — no animation, so nothing fights the layout
                scrollBottom(proxy, delay: 0.05)
                if !s { scrollBottom(proxy, delay: 0.25) }
            }
            .onChange(of: viewModel.messages.count) { _ in scrollBottom(proxy, delay: 0.05) }
            .onChange(of: viewModel.messages.last?.content) { _ in
                // while streaming, follow the text at most ~7x/second instead of on every token batch
                guard viewModel.isStreaming, !scrollPending else { return }
                scrollPending = true
                scrollBottom(proxy, delay: 0.14) { scrollPending = false }
            }
        }
    }

    private func scrollBottom(_ proxy: ScrollViewProxy, delay: Double, done: (() -> Void)? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { proxy.scrollTo("bottom", anchor: .bottom) }
            done?()
        }
    }

    @ViewBuilder
    private func cardView(_ card: AiCard, id: UUID) -> some View {
        switch card {
        case .live:
            AiLiveCard()
        case .recipe(let d):
            AiRecipeCard(draft: d)
        case .dylibDraft(let d):
            AiDylibDraftCard(draft: d) { job in viewModel.setCard(messageID: id, .authored(jobID: job, name: d.name)) }
        case .authored(let job, let name):
            AiAuthoredCard(jobID: job, name: name).id(job)
        case .crash(let job, let name, let matches, let check):
            AiCrashCard(jobID: job, name: name, matches: matches, check: check)
        case .dylibPlan(let plan):
            AiDylibPlanCard(plan: plan)
        case .liveRelease(let d):
            AiLiveReleaseCard(draft: d)
        case .patch(let job, let pid, let name):
            AiPatchCard(jobID: job, patchID: pid, name: name).id(pid)
        case .colorPicker(let hex):
            AiColorPickerCard(initialHex: hex) { applied in viewModel.setColorCard(messageID: id, hex: applied) }
        case .apps(let picks):
            AiAppsCard(picks: picks) { pick in viewModel.tapApp(pick) }
        case .libraries(let lib):
            AiLibrariesCard(card: lib, isBusy: viewModel.isStreaming, onRun: { selected in
                viewModel.decryptAndReconstruct(lib, selected: selected)
            }, onVersionChange: { version in
                viewModel.changeVersion(lib, to: version)
            })
        case .reconResults(let results):
            AiReconResultsCard(results: results, onDownload: { result in
                Task {
                    if let url = await viewModel.downloadRecovered(result) { SharePresenter.present(url) }
                }
            }, onEdit: { result in
                ReconEditorPresenter.present(jobID: result.jobID, dylibName: result.dylibName)
            })
        }
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(.red)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.1))
    }

    private var chatLayer: some View {
        ZStack(alignment: .top) {
            AppBackground().ignoresSafeArea()
            messageList
                .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
                .onChange(of: photoItem) { _ in handlePickedPhoto() }
            LinearGradient(colors: [Color.black.opacity(0.9), Color.black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 96)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
            // swipe in from the left edge to open the chat list (only the 16pt strip takes touches)
            Color.clear.frame(width: 16)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 10).onEnded { g in
                    if g.translation.width > 40 { setSidebar(true) }
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            topBar
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let error = viewModel.errorText { errorBanner(error) }
                if let n = viewModel.notice {
                    Text(n).font(.caption.weight(.semibold)).foregroundStyle(Color.dtAccent)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 4)
                }
                if !viewModel.pendingAttachments.isEmpty || viewModel.binaryAttachment != nil || viewModel.pendingImage != nil { attachmentChips }
                if viewModel.messages.isEmpty, AiDylibTool.available {
                    AiDylibTemplateRow { t in
                        let seed = t.seedPrompt.isEmpty ? "I want a new dylib: " : t.seedPrompt
                        viewModel.draft = t.id == "blank" ? seed : "\(seed) [template: \(t.id)]"
                    }
                    .padding(.bottom, 4)
                }
                // one bar: a slim usage strip on top, a grey divider, then the composer
                VStack(spacing: 0) {
                    AIUsageBar(usage: shownUsage, compact: true)
                    Rectangle().fill(Color.white.opacity(0.14)).frame(height: 0.5)
                    composer
                        .sheet(isPresented: $showGifPicker) { AiGifPickerSheet { viewModel.sendGif($0) } }
                }
                .aiGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
            }
        }
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            Button { setSidebar(true) } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                    .aiGlassCircle(46)
                    .overlay(alignment: .topTrailing) {
                        if viewModel.isStreaming { Circle().fill(Color.dtAccent).frame(width: 11, height: 11).offset(x: -4, y: 4) }
                    }
            }
            Spacer()
            HStack(spacing: 0) {
                Button { viewModel.newChat() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 19, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 50, height: 46)
                }
                Menu {
                    Button { if let url = viewModel.exportTranscript() { SharePresenter.present(url) } } label: { Label("Share", systemImage: "square.and.arrow.up") }
                    Button { viewModel.togglePin(viewModel.currentID) } label: {
                        Label(viewModel.isCurrentPinned ? "Unpin" : "Pin", systemImage: viewModel.isCurrentPinned ? "pin.slash" : "pin")
                    }
                    Button { viewModel.learnStyleFromChat() } label: { Label("Use this chat's style", systemImage: "wand.and.stars") }
                    Button { viewModel.showColorWheel() } label: { Label("Colour wheel", systemImage: "paintpalette") }
                    Button { showGifPicker = true } label: { Label("Send a GIF", systemImage: "face.smiling") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    if !embedded { Button { dismiss() } label: { Label("Close", systemImage: "xmark") } }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 50, height: 46)
                }
            }
            .aiGlass(Capsule())
        }
        .padding(.horizontal, 14).padding(.top, 6)
        .confirmationDialog("Delete this chat?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { viewModel.delete(viewModel.currentID) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var composer: some View {
        HStack(spacing: 4) {
            Menu {
                Button { showPhotoPicker = true } label: { Label("Photos", systemImage: "photo") }
                Button { pickFiles() } label: { Label("Files", systemImage: "paperclip") }
                Button { showWebpageAlert = true } label: { Label("Webpage", systemImage: "globe") }
                Button { showGifPicker = true } label: { Label("GIF", systemImage: "face.smiling") }
                Button { viewModel.showColorWheel() } label: { Label("Colour wheel", systemImage: "paintpalette") }
                Toggle(isOn: $viewModel.thinkHarder) { Label("Think harder", systemImage: "brain") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
            }

            if viewModel.thinkHarder { Image(systemName: "brain").font(.system(size: 15)).foregroundStyle(Color.dtAccent) }
            TextField("Message Ai-Decrypt", text: $viewModel.draft, axis: .vertical)
                .font(.system(size: 17))
                .foregroundStyle(.white)
                .lineLimit(1...6)
                .focused($inputFocused)
                .padding(.vertical, 8)

            Button {
                inputFocused = false
                viewModel.isStreaming ? viewModel.cancel() : viewModel.send()
            } label: {
                Image(systemName: viewModel.isStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.dtOnAccent)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.dtAccent))
            }
            .disabled(
                viewModel.draft.trimmingCharacters(in: .whitespaces).isEmpty
                    && viewModel.pendingAttachments.isEmpty
                    && viewModel.binaryAttachment == nil
                    && viewModel.pendingImage == nil
                    && !viewModel.isStreaming
            )
            .opacity(viewModel.draft.trimmingCharacters(in: .whitespaces).isEmpty && !viewModel.isStreaming
                     && viewModel.pendingAttachments.isEmpty && viewModel.binaryAttachment == nil && viewModel.pendingImage == nil ? 0.45 : 1)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
    }
}

// MARK: - Saved chats

private struct AiHistorySheet: View {
    @ObservedObject var vm: AiDecryptViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if vm.conversations.isEmpty {
                    Text("No saved chats yet.").foregroundStyle(.secondary)
                }
                ForEach(vm.conversations) { c in
                    Button { vm.open(c.id); dismiss() } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(c.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                if c.id == vm.currentID {
                                    Text("current").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.dtAccent)
                                }
                            }
                            Text("\(c.messages.count) messages · \(c.updated.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { idx in
                    let ids = idx.map { vm.conversations[$0].id }
                    ids.forEach { vm.delete($0) }
                }
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Live progress

/// What the model is doing right now, with real counters instead of a fake percentage.
private struct AiLiveStrip: View {
    let live: AiLiveStats

    private var label: String {
        switch live.phase {
        case .reading: return "Reading your message"
        case .reasoning: return "Reasoning it through"
        case .writing: return "Writing the answer"
        case .toolCall: return "Preparing a tool call"
        case .running(let n): return "Running \(n)"
        case .remembering: return "Saving earlier chat to memory"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AIActivityBars()
                Text(label).font(.subheadline.weight(.semibold))
                Spacer()
                TimelineView(.periodic(from: live.startedAt, by: 1)) { ctx in
                    let s = max(0, Int(ctx.date.timeIntervalSince(live.startedAt)))
                    Text(s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            AIShimmerLine()
            if live.tokens > 0 {
                HStack(spacing: 12) {
                    Label("\(live.tokens) tokens", systemImage: "number")
                    if live.tps > 0 { Label(String(format: "%.1f tok/s", live.tps), systemImage: "bolt.fill") }
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Message bubble

private struct AiMessageBubble: View, Equatable {
    let message: AiChatMessage
    static func == (a: AiMessageBubble, b: AiMessageBubble) -> Bool { a.message == b.message }

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 6) {
                if let data = message.imageData, let ui = UIImage(data: data) {
                    Image(uiImage: ui).resizable().scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if let g = message.gifURL { RemoteGIF(url: g) }
                if message.role == .assistant {
                    if !message.content.isEmpty { MarkdownView(EmojiShortcodes.expand(message.content)) }
                    if let m = message.meta {
                        Text(m).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(Array(contentBlocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .text(let text):
                            Text(text).font(.subheadline).foregroundStyle(.white).textSelection(.enabled)
                        case .code(let lang, let code):
                            AiCodeBlockView(language: lang, code: code).padding(.vertical, 4)
                        }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(message.role == .user ? Color.dtAccent.opacity(0.16) : Color.white.opacity(0.045))
            )
            if message.role == .assistant { Spacer(minLength: 32) }
        }
    }

    private enum Block { case text(String); case code(lang: String, code: String) }

    private var contentBlocks: [Block] {
        var blocks: [Block] = []
        let parts = message.content.components(separatedBy: "```")
        for (i, part) in parts.enumerated() {
            if i % 2 == 0 {
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { blocks.append(.text(trimmed)) }
            } else {
                var lines = part.components(separatedBy: "\n")
                let lang = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
                if !lines.isEmpty { lines.removeFirst() }
                blocks.append(.code(lang: lang, code: lines.joined(separator: "\n").trimmingCharacters(in: .newlines)))
            }
        }
        if blocks.isEmpty && !message.content.isEmpty { blocks.append(.text(message.content)) }
        return blocks
    }
}

private struct AiCodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Text(copied ? "Copied" : "Copy").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(0.03))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.dtGreen).padding(8)
            }
        }
        .background(Color.black.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

#Preview {
    AiDecryptChatView().environmentObject(RepoStore())
}
