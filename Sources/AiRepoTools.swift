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

// MARK: - Reconstruct (the real /api/staff/decomp engine)

struct ReconResult: Equatable {
    let dylibName: String
    let summary: String
    let downloadPath: String?   // GET this (staff-gated) to get the recovered project zip
}

/// Drives the site's own Ghidra/lifter reconstruction engine, already mounted at /api/staff/decomp (staff-gated;
/// the app's signed-in staff session + x-dt header pass the guard). Flow: upload a Mach-O (one dylib/framework
/// binary) → poll the job → the recovered Objective-C project is downloadable from the job.
enum ReconstructAPI {
    static let base = "/api/staff/decomp"

    private struct Started: Decodable { var id: String }
    private struct Part: Decodable { var name: String?; var dylibName: String?; var error: String? }
    private struct Item: Decodable { var name: String?; var state: String?; var error: String?; var parts: [Part]? }
    private struct Job: Decodable { var state: String; var log: [String]?; var items: [Item]? }

    /// Uploads one binary and polls to completion. Ghidra reconstruction is slow (often minutes), so this can run
    /// a long time; `progress` streams the job's own log lines.
    static func reconstruct(name: String, data: Data, progress: @escaping (String) -> Void) async throws -> ReconResult {
        let encName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let startData = try await Api.shared.upload("POST", "\(base)/upload?name=\(encName)", body: data)
        guard let started = try? JSONDecoder().decode(Started.self, from: startData) else {
            throw ApiError.server("The reconstruct engine didn't return a job id (are you signed in as staff?).", 0)
        }
        var misses = 0
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 3_000_000_000)
            do {
                let job: Job = try await Api.shared.get("\(base)/jobs/\(started.id)"); misses = 0
                if let line = job.log?.last { await MainActor.run { progress(line) } }
                if job.state == "error" {
                    throw ApiError.server(job.items?.first?.error ?? "Reconstruction failed.", 0)
                }
                if job.state == "done" {
                    let part = job.items?.first?.parts?.first
                    let dyl = part?.dylibName ?? part?.name ?? name
                    return ReconResult(dylibName: dyl, summary: "Reconstructed \(dyl)",
                                       downloadPath: "\(base)/jobs/\(started.id)/download?item=0&part=0")
                }
            } catch let e as ApiError where e.status == 0 { throw e }
            catch { misses += 1; if misses > 200 { throw error } }   // tolerate long Ghidra runs
        }
    }
}
