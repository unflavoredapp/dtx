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
    var jobID: String = ""      // the decomp job, for browsing/editing/rebuilding its source
    var appURL: String? = nil   // the IPA this dylib was pulled from, so dylib-aimed tools can run against it
    var appName: String? = nil
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
                                       downloadPath: "\(base)/jobs/\(started.id)/download?item=0&part=0",
                                       jobID: started.id)
                }
            } catch let e as ApiError where e.status == 0 { throw e }
            catch { misses += 1; if misses > 200 { throw error } }   // tolerate long Ghidra runs
        }
    }

    // MARK: Browsing / editing / rebuilding the recovered project

    struct DecompFile: Decodable, Identifiable, Equatable { var id: String { path }; let path: String; let size: Int }
    private struct FilesReply: Decodable { let files: [DecompFile] }
    private struct BuildState: Decodable { var state: String; var log: [String]?; var dylibName: String? }

    private static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }

    static func files(jobID: String) async throws -> [DecompFile] {
        let r: FilesReply = try await Api.shared.get("\(base)/jobs/\(jobID)/files")
        return r.files
    }

    static func readFile(jobID: String, path: String) async throws -> String {
        let data = try await Api.shared.request("GET", "\(base)/jobs/\(jobID)/file?path=\(enc(path))")
        return String(decoding: data, as: UTF8.self)
    }

    static func writeFile(jobID: String, path: String, text: String) async throws {
        _ = try await Api.shared.upload("PUT", "\(base)/jobs/\(jobID)/file?path=\(enc(path))", body: Data(text.utf8))
    }

    /// Compiles the (possibly hand-edited) recovered project back into a dylib, polling to completion and
    /// returning the built dylib's filename. Throws with the server's message if there's no iOS SDK (409).
    static func build(jobID: String, progress: @escaping (String) -> Void) async throws -> String {
        _ = try await Api.shared.request("POST", "\(base)/jobs/\(jobID)/build")
        var misses = 0
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 2_500_000_000)
            do {
                let s: BuildState = try await Api.shared.get("\(base)/jobs/\(jobID)/build"); misses = 0
                if let line = s.log?.last { await MainActor.run { progress(line) } }
                if s.state == "error" { throw ApiError.server(s.log?.last ?? "Build failed.", 0) }
                if s.state == "done" { return s.dylibName ?? "built.dylib" }
            } catch let e as ApiError where e.status == 0 { throw e }
            catch { misses += 1; if misses > 160 { throw error } }
        }
    }

    static func dylibDownloadPath(jobID: String) -> String { "\(base)/jobs/\(jobID)/dylib" }
    /// The whole project (sources + the latest built dylib) zipped fresh from the files on the server.
    static func zipDownloadPath(jobID: String) -> String { "\(base)/jobs/\(jobID)/download?item=0&part=0" }
}
