import Foundation

/// decrawl_search: lets the chat model look things up in Decrawl (our own crawler and search index of iOS tweak,
/// jailbreak and reverse-engineering sources) while it decrypts, analyses or reconstructs a dylib. The answer is
/// real crawled text with source links, so the model can ground what a class or function does instead of guessing.
enum AiDecrawlTool {
    static let name = "decrawl_search"

    static let schema: [String: Any] = [
        "type": "function",
        "function": [
            "name": name,
            "description": "Search Decrawl, our own index of crawled iOS jailbreak / tweak / TrollStore / reverse-engineering pages and confirmed facts. Use it BEFORE guessing what a class, method, function, framework, tweak or dylib does, when reconstructing or explaining a decrypted dylib or app, and when a build error needs a known fix. Search with specific names (e.g. a class name, a method selector, a tweak name, an error message). Treat the results as reference: quote the source link, and never present a result as a fact about this binary unless the evidence in the project agrees.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "What to look up. Specific names work best, e.g. \"BBAES AES encrypt NSString category\" or \"method_setImplementation swizzle iOS tweak\"."],
                ],
                "required": ["query"],
            ] as [String: Any],
        ] as [String: Any],
    ]

    static func query(_ arguments: String) -> String {
        guard let d = arguments.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "" }
        return ((o["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Reply: Decodable { let ok: Bool?; let text: String?; let error: String? }

    static func run(_ query: String) async -> String {
        guard query.count >= 3 else { return "Give decrawl_search a specific query (at least 3 characters)." }
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        do {
            let r: Reply = try await Api.shared.get("/api/decrawl/search?q=" + String(q.prefix(300)), timeout: 15)
            let t = (r.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if r.ok == true, !t.isEmpty { return "Decrawl results (reference only, verify against the binary):\n" + t }
            return r.error ?? "Decrawl found nothing for that query. Try a more specific name, or answer from the evidence you already have and say it is unconfirmed."
        } catch {
            return "Decrawl could not be reached right now (\(error.localizedDescription)). Continue from the evidence you have and say it is unconfirmed."
        }
    }
}
