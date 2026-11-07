import SwiftUI

/// DTX wallet + Hub data from the server (`/api/dtx/*`). Signed-in people only; guests get a sign-in prompt.
struct DTXHub: Decodable {
    struct User: Decodable { var username: String?; var photoUrl: String?; var role: String?; var premium: Bool?; var address: String? }
    struct Cert: Decodable { var active: Bool?; var expires: String? }
    struct Usage: Decodable { var count: Int; var dtx: Int }
    struct Scratch: Decodable { var available: Bool; var prize: String? }
    struct Top: Decodable, Identifiable { var id: String; var views: Int; var downloads: Int }
    struct Entry: Decodable, Identifiable { var id: Int; var delta: Int; var label: String; var at: Double }

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

/// 1234 -> "1.2K"
func compactCount(_ n: Int) -> String {
    switch n {
    case ..<1000: return "\(n)"
    case ..<1_000_000: return String(format: "%.1fK", Double(n) / 1000).replacingOccurrences(of: ".0K", with: "K")
    default: return String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
    }
}
