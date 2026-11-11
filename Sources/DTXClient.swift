import SwiftUI

/// DTX wallet + Hub data from the server (`/api/dtx/*`). Signed-in people only; guests get a sign-in prompt.
struct DTXHub: Decodable {
    struct User: Decodable { var username: String?; var photoUrl: String?; var role: String?; var premium: Bool?; var address: String? }
    struct Cert: Decodable { var active: Bool?; var expires: String? }
    struct Usage: Decodable { var count: Int; var dtx: Int }
    struct Scratch: Decodable { var available: Bool; var prize: String? }
    struct Top: Decodable, Identifiable { var id: String; var views: Int; var downloads: Int }
    struct Entry: Decodable, Identifiable { var id: Int; var delta: Int; var label: String; var at: Double }
    /// AI pricing: DTX per 1,000 tokens, the multiplier for messages with images, and the smallest charge.
    struct Rates: Decodable { var aiPerKTokens: Double?; var aiVisionX: Double?; var aiMin: Double? }

    var signedIn: Bool
    var user: User?
    var certificate: Cert?
    var balance: Int?
    var usageToday: [String: Usage]?
    var spentToday: Int?
    var scratch: Scratch?
    var prices: [String: Int]?
    var topApps: [Top]?
    var history: [Entry]?
    var rates: Rates?
    /// Staff and admin: nothing is charged.
    var unmetered: Bool?
}

struct DTXStat: Decodable { var views: Int; var downloads: Int }
private struct DTXStatsReply: Decodable { var stats: [String: DTXStat] }
struct DTXScratchReply: Decodable { var prize: String; var dtx: Int; var certificate: Bool; var balance: Int }

@MainActor
final class DTXWallet: ObservableObject {
    static let shared = DTXWallet()

    @Published var hub: DTXHub?
    @Published var loading = false
    @Published var error: String?
    @Published var stats: [String: DTXStat] = [:]

    var balance: Int { hub?.balance ?? 0 }

    /// What a reply of this many tokens costs in DTX. Same sum as the server's (dtx-api.js aiCost), with its
    /// defaults until the hub has loaded: 1 DTX per 1K tokens, x2 with images, at least 1.
    func aiCost(tokens: Int, vision: Bool = false) -> Int {
        let perK = hub?.rates?.aiPerKTokens ?? 1, visionX = hub?.rates?.aiVisionX ?? 2, least = hub?.rates?.aiMin ?? 1
        let cost = (Double(max(tokens, 0)) / 1000 * perK * (vision ? visionX : 1)).rounded(.up)
        return Int(max(least, cost))
    }

    /// Added to the AI's system prompt so it knows what DTX is, what things cost and what this person has.
    var promptText: String {
        func num(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }
        let r = hub?.rates
        var lines = [
            "## DTX",
            "DTX is this app's coin. Every AI reply and every decrypt tool is paid for in DTX; there is no free tier.",
            "AI replies cost \(num(r?.aiPerKTokens ?? 1)) DTX per 1,000 tokens (x\(num(r?.aiVisionX ?? 2)) when the message has images), at least \(num(r?.aiMin ?? 1)) DTX per reply. Always talk about cost in DTX, never in tokens.",
        ]
        if let p = hub?.prices, !p.isEmpty {
            lines.append("Tool prices in DTX: " + p.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ".")
        }
        if hub?.signedIn == true {
            if hub?.unmetered == true { lines.append("This person is staff: nothing is charged to them.") }
            else { lines.append("This person's balance is \(balance) DTX. If it is too low for what they ask, say so and point them to the Hub (daily scratch card, wallet).") }
        } else {
            lines.append("This person is not signed in, so they have no DTX wallet yet. Signing in with Telegram creates one.")
        }
        return lines.joined(separator: "\n")
    }

    func refresh() async {
        loading = true; defer { loading = false }
        do {
            hub = try await Api.shared.get("/api/dtx/hub", timeout: 12)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func scratch() async throws -> DTXScratchReply {
        let r: DTXScratchReply = try await Api.shared.post("/api/dtx/scratch")
        await refresh()
        return r
    }

    /// Views and downloads are counted once per person per app per day on the server.
    func track(_ bundleID: String, _ kind: String) {
        guard !bundleID.isEmpty else { return }
        Task.detached { _ = try? await Api.shared.request("POST", "/api/dtx/track", json: ["app": bundleID, "kind": kind], timeout: 8) }
    }

    func loadStats(_ ids: [String]) async {
        let want = Array(Set(ids)).filter { stats[$0] == nil }.prefix(200)
        guard !want.isEmpty else { return }
        let q = want.joined(separator: ",").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let r: DTXStatsReply = try? await Api.shared.get("/api/dtx/stats?ids=" + q, timeout: 10) {
            for (k, v) in r.stats { stats[k] = v }
        }
    }
}

/// The DTX coin artwork, used wherever a DTX amount is shown.
struct DTXCoin: View {
    var size: CGFloat = 16
    var body: some View { Image("DTXCoin").resizable().scaledToFit().frame(width: size, height: size) }
}

/// 1234 -> "1.2K"
func compactCount(_ n: Int) -> String {
    switch n {
    case ..<1000: return "\(n)"
    case ..<1_000_000: return String(format: "%.1fK", Double(n) / 1000).replacingOccurrences(of: ".0K", with: "K")
    default: return String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
    }
}
