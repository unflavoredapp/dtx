import Foundation

/// Signing on the Decrypt.Team server (`/api/sign/*`, server/sign-api.js): the server fetches the IPA itself, a
/// core-pinned worker runs zsign on it, and the phone installs the result over the air from our domain.
enum RemoteSign {
    struct Job: Decodable { var id: String; var position: Int?; var workers: Int? }
    /// One log line: the worker that wrote it (0 = the server itself) and microseconds since the job was accepted.
    struct Line: Decodable { var w: Int; var us: Int; var t: String }
    struct Result: Decodable, Equatable {
        var ipa: String
        var manifest: String
        /// the itms-services link iOS installs from
        var install: String
        var size: Int64?
        var name: String
        var bundleId: String
        var version: String
        /// how long the server keeps the signed IPA
        var minutes: Int?
    }
    struct Status: Decodable {
        var state: String          // queued | running | done | failed
        var position: Int?
        var worker: Int?
        var cores: String?
        var lines: [Line]
        var next: Int
        var error: String?
        var result: Result?
    }

    static func start(_ body: [String: Any]) async throws -> Job {
        try await Api.shared.post("/api/sign/jobs", json: body, timeout: 90)
    }

    static func status(_ id: String, since: Int) async throws -> Status {
        try await Api.shared.get("/api/sign/jobs/\(id)?since=\(since)", timeout: 15)
    }
}
