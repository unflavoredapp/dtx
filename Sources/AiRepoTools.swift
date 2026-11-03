import Foundation

/// Backend calls behind the Ai-Decrypt repo flow: search the loaded apps, list an app's saved dylibs/frameworks,
/// check for a newer App Store version, decrypt the latest build, and reconstruct a selected dylib.
///
/// The search/dylibs/upstream/decrypt endpoints are the same ones AppDetailView and BuildView already use.
/// Reconstruct is a dedicated endpoint whose exact path/shape lives in ONE place below (ReconstructAPI) — correct
/// those two constants once the backend route is confirmed and the whole flow follows.
enum AiRepoTools {

    // MARK: Tool schema (the model calls this to start the flow)

    static let searchAppsSchema: [String: Any] = [
        "type": "function",
        "function": [
            "name": "search_apps",
            "description": "Searches the user's repo library for apps matching a name and shows them as tappable cards. Use this whenever the person names an app they want to inspect, decrypt, or reconstruct.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "The app name or part of it to search for."],
                ],
                "required": ["query"],
            ] as [String: Any],
        ] as [String: Any],
    ]

    static func extractQuery(_ argumentsJSON: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let q = obj["query"] as? String else { return "" }
        return q
    }

    // MARK: App library (saved dylibs / frameworks)

    /// The saved dylib/framework sets for an app, newest version first. Same endpoint as AppDetailView.
    static func libraries(bid: String) async throws -> [SavedSet] {
        let encoded = bid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? bid
        let reply: SetsReply = try await Api.shared.get("/api/dylibs/app/" + encoded)
        return (reply.sets ?? []).sorted { compareVersions($0.version, $1.version) > 0 }
    }

    // MARK: Update check (is there a newer App Store build?)

    struct UpdateInfo {
        let storeID: String?       // numeric App Store id, needed to decrypt the latest build
        let storeVersion: String?  // newest version on the App Store
        let haveVersions: [String] // versions already decrypted / saved
        var hasUpdate: Bool {
            guard let sv = storeVersion, !sv.isEmpty else { return false }
            return !haveVersions.contains(sv)
        }
    }

    static func updateInfo(bid: String) async throws -> UpdateInfo {
        let encoded = bid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? bid
        let reply: UpstreamReply = try await Api.shared.get("/api/repo/upstream?bids=" + encoded)
        let item = reply.items?[bid] ?? reply.items?.values.first
        return UpdateInfo(
            storeID: item?.store?.id,
            storeVersion: item?.store?.ver,
            haveVersions: (item?.library ?? []).map { $0.ver }
        )
    }

    // MARK: Decrypt the latest App Store build

    private struct DecStart: Decodable { var id: String }
    private struct DecState: Decodable { var status: String; var msg: String?; var error: String?; var up: String?; var queue: Int? }

    /// Kicks off a server decrypt of an App Store app and polls until it's done, returning the decrypted IPA URL (`up`).
    /// `progress` is called on the main actor with human-readable status lines. Same flow as BuildView's store path.
    static func decryptLatest(storeID: String, version: String?, progress: @escaping (String) -> Void) async throws -> String {
        var body: [String: Any] = ["url": "https://apps.apple.com/app/id" + storeID]
        if let version, !version.isEmpty { body["version"] = version }
        let start: DecStart = try await Api.shared.post("/api/decrypt", json: body)
        var misses = 0
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            do {
                let s: DecState = try await Api.shared.get("/api/decrypt/" + start.id); misses = 0
                if s.status == "error" { throw ApiError.server(s.error ?? "The decrypt failed.", 0) }
                if s.status == "done", let up = s.up { return up }
                await MainActor.run { progress(s.msg ?? "Decrypting on the server…") }
            } catch let e as ApiError where e.status == 0 { throw e }
            catch { misses += 1; if misses > 30 { throw error } }
        }
    }
}

// MARK: - Reconstruct (dedicated backend endpoint)

/// ⚠️ CONFIRM THESE TWO AGAINST THE BACKEND. The reconstruct endpoint is a dedicated route; everything else in the
/// flow is already wired to confirmed endpoints. Adjust `startPath`, the request `body`, and the `Result` fields to
/// match the real route, and the whole Decrypt→Reconstruct flow follows with no other changes.
enum ReconstructAPI {
    /// Assumed: POST /api/reconstruct { ipa: <decrypted IPA url>, dylib: <name> } -> { id }, then poll
    /// GET /api/reconstruct/{id} -> { status: queued|working|done|error, msg, error, url (finished output) }.
    static let startPath = "/api/reconstruct"

    private struct Start: Decodable { var id: String }
    private struct State: Decodable { var status: String; var msg: String?; var error: String?; var url: String? }

    /// Reconstructs one dylib from a decrypted IPA, polling to completion and returning the finished artifact URL.
    static func run(ipaURL: String, dylib: String, progress: @escaping (String) -> Void) async throws -> String {
        let body: [String: Any] = ["ipa": ipaURL, "dylib": dylib]
        let start: Start = try await Api.shared.post(startPath, json: body)
        var misses = 0
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            do {
                let s: State = try await Api.shared.get("\(startPath)/" + start.id); misses = 0
                if s.status == "error" { throw ApiError.server(s.error ?? "Reconstruction failed.", 0) }
                if s.status == "done" { return s.url ?? "" }
                await MainActor.run { progress(s.msg ?? "Reconstructing \(dylib)…") }
            } catch let e as ApiError where e.status == 0 { throw e }
            catch { misses += 1; if misses > 60 { throw error } }
        }
    }
}
