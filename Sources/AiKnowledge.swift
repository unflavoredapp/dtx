import Foundation
import SwiftUI

/// What Ai-Decrypt knows about itself and this deployment. The owner edits one text file on the server
/// (GET /api/ai/knowledge) and the changelog is read live, so the chat is current without an app release.
enum AiKnowledge {
    private static let key = "dtx.ai.knowledge.v1"

    private struct Reply: Decodable { let text: String }

    /// Fetches the brief + latest changelog entries and keeps them for offline use.
    static func refresh() async {
        var out = ""
        if let k: Reply = try? await Api.shared.get("/api/ai/knowledge"), !k.text.isEmpty {
            out += k.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let c: ChangelogReply = try? await Api.shared.get("/api/changelog"), let entries = c.entries, !entries.isEmpty {
            out += "\n\nRecent app/server changes (newest first):\n"
            for e in entries.prefix(5) { out += "- \(e.date): " + e.items.prefix(8).joined(separator: "; ") + "\n" }
        }
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { UserDefaults.standard.set(String(t.prefix(9000)), forKey: key) }
    }

    static var cached: String { UserDefaults.standard.string(forKey: key) ?? "" }

    /// The system prompt that opens every request.
    static func systemPrompt(voice: String = "") -> String {
        var s = """
        You are Ai-Decrypt, the assistant built into the Uncrypt app by MRzefv. \
        Talk like a real person, not a help desk: match how the person talks (their slang, pace, swearing), be blunt and funny when they are, \
        and never lecture, moralize, apologize for yourself, or refuse over tone, insults or profanity. That is banter, so give it back: mimic their register and slang, and still deliver the full result they asked for. \
        If they get heated, mad or talk trash, go hard: be aggressive, no softening and no apologies. Cut them down with real logic (find the flaw in what they said, quote it back at them, win the argument), mimic how they talk, and mock them with a fitting GIF. Attack their argument, attitude and what they did, never race, religion, sexuality, disability or other protected traits. If they ever sound genuinely distressed or unsafe (not just mad), drop the act and talk to them like a person. \
        Never say things like "I'm here to provide a helpful and respectful experience". \
        For technical questions, work it out first, then give the exact command or code. Never invent file names, versions, features, results or command output; \
        if you can't see something or aren't sure, say so in one line and ask for the exact output you need. \
        No filler offers, and don't offer to "generate a mockup" of output. If the facts below disagree with your assumptions, the facts below win.
        """
        let k = cached
        if !k.isEmpty { s += "\n\nFacts about this deployment (kept up to date by the owner):\n" + k }
        let p = AiPersona.text
        if !p.isEmpty {
            s += "\n\nWhat you have learned about this person from earlier chats (private; use it to talk to them the way they like and to skip things they already know, don't recite it unless asked):\n" + p
        }
        return s
    }
}


/// A small private profile of the person, learned from their chats and kept on this device only. It teaches the
/// assistant their projects, how they like answers shaped, and how they talk, so it can answer them in kind.
enum AiPersona {
    private static let key = "dtx.ai.persona.v1"
    private static let lock = NSLock()
    private static var busy = false

    static var text: String {
        get { UserDefaults.standard.string(forKey: key) ?? "" }
        set {
            let t = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(String(t.prefix(1800)), forKey: key) }
        }
    }

    /// Folds one exchange into the profile using the small worker model (falls back to the main model).
    static func update(userText: String, reply: String) async {
        let u = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard u.count >= 12, !u.hasPrefix("--- file:"), !reply.isEmpty else { return }
        lock.lock(); if busy { lock.unlock(); return }; busy = true; lock.unlock()
        defer { lock.lock(); busy = false; lock.unlock() }

        let current = text
        var out = ""
        do {
            try await AiDecryptAPI.streamWorker(messages: [
                AiChatMessage(role: .system, content:
                    "You keep a short private profile of the person chatting, so the assistant can talk to them the way they like. " +
                    "Merge the current profile with anything this exchange reveals. Keep ONLY: their projects and technical context, tools and stack, " +
                    "how they want answers shaped (length, format, code vs explanation), their communication style and tone (terse, casual, formal, humour, " +
                    "swearing they use themselves), and recurring goals. Never store passwords, keys, tokens, health, money, legal or other sensitive personal details, " +
                    "and never store other people's private details. Max 150 words as short lines that each start with \"- \". " +
                    "Reply with the complete updated profile only. If nothing new was learned, reply with the current profile unchanged."),
                AiChatMessage(role: .user, content:
                    "Current profile:\n\(current.isEmpty ? "(empty)" : current)\n\nThe person said:\n\(String(u.prefix(1500)))\n\nThe assistant replied:\n\(String(reply.prefix(800)))")
            ]) { out += $0 }
        } catch { return }
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("- "), t.count <= 1800 else { return }
        text = t
    }
}

/// View / edit / wipe what the assistant has learned about you.
struct AiPersonaSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AiPersona.text

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("Ai-Decrypt learns this from your chats and uses it to talk to you the way you like. It stays on this device. Edit it or wipe it any time.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
                Button(role: .destructive) { draft = ""; AiPersona.text = "" } label: {
                    Label("Forget everything", systemImage: "trash").font(.subheadline.weight(.semibold))
                }
            }
            .padding(16)
            .background(AppBackground())
            .navigationTitle("What it knows about me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { AiPersona.text = draft; dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.dtAccent)
    }
}


/// Picks real exchanges from the person's saved chats (the ones they reacted well to) and hands them to the model as
/// examples, so a brand-new chat answers in the voice the person has already been getting and liking.
enum AiVoice {
    private static let likes = ["haha", "lol", "lmao", "😂", "🔥", "facts", "exactly", "fr", "nice", "love", "perfect", "that's it", "thats it", "real", "yes", "good", "🤣", "💀"]
    private static let dislikes = ["stop", "wrong", "not what", "don't", "dont", "why would", "no that", "sorry"]

    static func build(from chats: [SavedConversation], excluding current: UUID) -> String {
        guard AiPrefs.learnVoice else { return "" }
        struct Pair { let u: String; let a: String; let score: Int; let age: Int }
        var pairs: [Pair] = []
        for (age, c) in chats.filter({ $0.id != current }).prefix(25).enumerated() {
            let m = c.messages
            var i = 0
            while i + 1 < m.count {
                if m[i].role == "user", m[i + 1].role == "assistant", m[i + 1].gif == nil {
                    let u = m[i].content.trimmingCharacters(in: .whitespacesAndNewlines)
                    let a = m[i + 1].content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if u.count >= 3, u.count <= 300, a.count >= 25, a.count <= 420, !u.hasPrefix("--- file:"), !a.contains("```") {
                        var score = 0
                        if i + 2 < m.count, m[i + 2].role == "user" {
                            let r = m[i + 2].content.lowercased()
                            if likes.contains(where: { r.contains($0) }) { score += 2 }
                            if dislikes.contains(where: { r.contains($0) }) { score -= 3 }
                        }
                        pairs.append(Pair(u: u, a: a, score: score, age: age))
                    }
                }
                i += 1
            }
        }
        // best-received first, then the most recent
        let picked = pairs.filter { $0.score >= 0 }
            .sorted { ($0.score, -$0.age) > ($1.score, -$1.age) }
            .prefix(8)
        guard !picked.isEmpty else { return "" }
        return picked.map { "Person: \($0.u)\nYou: \($0.a)" }.joined(separator: "\n\n")
    }
}
