import Foundation
import SwiftUI
import CryptoKit

// MARK: - Live Sync
//
// The installed IPA is the stable base. On open (and on demand) the app asks the server for a signed manifest and applies what changed:
//   layer 1  live configuration: feature flags, accent colour, tools shown / hidden / ordered / on by default, a banner, experimental switches
//   layer 2  plugins: server tools and recipes already load from the server; the manifest tells the app which versions exist
//   layer 3  native: a new IPA. The app only announces it; installing is still done by hand
// Everything applied here is data. Nothing downloaded is ever run as code.

enum Runtime {
    static let version = "2.0"
    static var build: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 1 }
}

enum LiveTheme { static var accent: Color? = nil }

// MARK: manifest

struct LiveEnvelope: Decodable { var payload: String?; var sig: String?; var key: String? }

struct LiveBannerInfo: Decodable, Equatable { var id: String; var title: String; var text: String; var url: String? }
struct LiveExperiment: Decodable, Identifiable { var id: String; var title: String; var detail: String? }
struct LiveConfig: Decodable {
    struct Theme: Decodable { var accent: String? }
    var flags: [String: Bool]?
    var theme: Theme?
    var hide: [String]?
    var order: [String]?
    var auto: [String: Bool]?
    var banner: LiveBannerInfo?
    var experimental: [LiveExperiment]?
}
struct LivePluginInfo: Decodable, Identifiable { var id: String; var name: String?; var version: String?; var kind: String? }
struct LiveRecipeInfo: Decodable, Identifiable { var id: String; var name: String?; var rev: String? }
struct LiveNative: Decodable { var build: Int?; var url: String?; var notes: String? }
struct LiveRelease: Decodable, Identifiable { var rev: Int; var at: String?; var note: String?; var channel: String?; var id: Int { rev } }

struct LiveManifest: Decodable {
    var issued: String?
    var channel: String?
    var rev: Int?
    var note: String?
    var minApp: Int?
    var config: LiveConfig?
    var native: LiveNative?
    var plugins: [LivePluginInfo]?
    var recipes: [LiveRecipeInfo]?
    var history: [LiveRelease]?
}

// MARK: saved state

struct LiveApplied: Codable { var rev: Int; var payload: String; var sig: String; var key: String; var at: Date; var note: String }
struct LiveLogEntry: Codable, Identifiable { var id = UUID(); var rev: Int; var event: String; var note: String; var at: Date }

@MainActor
final class LiveSync: ObservableObject {
    static let shared = LiveSync()

    enum KeyState: Equatable { case none, pinnedByApp, trusted, changed(String) }

    @Published private(set) var applied: LiveApplied?
    @Published private(set) var manifest: LiveManifest?          // the newest thing the server offered this person
    @Published private(set) var log: [LiveLogEntry] = []
    @Published private(set) var syncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError = ""
    @Published private(set) var keyState: KeyState = .none
    @Published private(set) var needsNative = false
    @Published private(set) var holdRev: Int?                    // set after a rollback: no automatic upgrades until "Resume updates"
    @Published var themeRev = 0
    @Published var channel: String { didSet { UserDefaults.standard.set(channel, forKey: "dt.live.channel") } }
    @Published var autoSync: Bool { didSet { UserDefaults.standard.set(autoSync, forKey: "dt.live.auto") } }

    private var appliedManifest: LiveManifest?
    private var pending: LiveEnvelope?                           // an update waiting for the person to trust a changed signing key
    private let defaults = UserDefaults.standard

    private init() {
        channel = defaults.string(forKey: "dt.live.channel") ?? "stable"
        autoSync = defaults.object(forKey: "dt.live.auto") as? Bool ?? true
        holdRev = defaults.object(forKey: "dt.live.hold") as? Int
        lastSync = defaults.object(forKey: "dt.live.last") as? Date
        load()
    }

    // MARK: what the rest of the app reads

    var config: LiveConfig { appliedManifest?.config ?? LiveConfig() }
    var rev: Int { applied?.rev ?? 0 }
    var plugins: [LivePluginInfo] { manifest?.plugins ?? appliedManifest?.plugins ?? [] }
    var recipes: [LiveRecipeInfo] { manifest?.recipes ?? appliedManifest?.recipes ?? [] }
    var native: LiveNative? { manifest?.native ?? appliedManifest?.native }
    var nativeNewer: Bool { (native?.build ?? 0) > Runtime.build }
    var updateAvailable: Bool { (manifest?.rev ?? 0) != rev && holdRev == nil && !needsNative }
    var pinnedKeyFingerprint: String? { fingerprint(of: pinnedKey()) }

    func flag(_ key: String, _ def: Bool = true) -> Bool { config.flags?[key] ?? def }
    func experimentOn(_ id: String) -> Bool { defaults.bool(forKey: "dt.live.exp." + id) }
    func setExperiment(_ id: String, _ on: Bool) { defaults.set(on, forKey: "dt.live.exp." + id); objectWillChange.send() }

    // MARK: sync

    /// Quietly syncs when it has been a while (used when the app opens or comes back).
    func syncIfDue() async {
        guard autoSync else { return }
        if let l = lastSync, Date().timeIntervalSince(l) < 15 * 60 { return }
        await sync()
    }

    func sync(rev: Int? = nil, hold: Bool = false) async {
        guard !syncing else { return }
        syncing = true; lastError = ""
        defer { syncing = false }
        do {
            var path = "/api/live/manifest?channel=\(channel)&build=\(Runtime.build)"
            if let rev { path += "&rev=\(rev)" }
            let env: LiveEnvelope = try await Api.shared.get(path, timeout: 15)
            lastSync = Date(); defaults.set(lastSync, forKey: "dt.live.last")
            try process(env, hold: hold ? rev : nil)
        } catch let e as ApiError where e.status == 404 {
            lastError = "This server has no live sync yet."
        } catch {
            lastError = error.localizedDescription
        }
    }

    func rollback(to rev: Int) async { await sync(rev: rev, hold: true) }

    func resume() async { holdRev = nil; defaults.removeObject(forKey: "dt.live.hold"); await sync() }

    func trustNewKey() {
        guard case .changed(let key) = keyState, let env = pending else { return }
        defaults.set(key, forKey: "dt.live.key"); keyState = .trusted
        do { try process(env, hold: nil) } catch { lastError = error.localizedDescription }
        pending = nil
    }

    private func process(_ env: LiveEnvelope, hold: Int?) throws {
        guard let payload = env.payload, let key = env.key else { throw LiveError("The server's update was incomplete.") }
        switch verify(env) {
        case .bad(let why): addLog(0, "rejected", why); throw LiveError(why)
        case .changed:
            pending = env; keyState = .changed(key)
            addLog(0, "held", "The signing key changed. Confirm it in the Update Center.")
            throw LiveError("The server is signing with a new key. Check it in the Update Center before applying anything.")
        case .ok: break
        }
        guard let data = payload.data(using: .utf8), let m = try? JSONDecoder().decode(LiveManifest.self, from: data) else { throw LiveError("The update couldn't be read.") }
        manifest = m
        if let need = m.minApp, need > Runtime.build {
            needsNative = true; addLog(m.rev ?? 0, "needs new app", "Release \(m.rev ?? 0) needs app build \(need) or newer.")
            return
        }
        needsNative = false
        if let hold { holdRev = hold; defaults.set(hold, forKey: "dt.live.hold") }
        else if holdRev != nil { return }                       // rolled back on purpose: keep it until the person resumes
        let r = m.rev ?? 0
        if r == rev, applied != nil { return }
        let previousAccent = config.theme?.accent
        let note = m.note ?? ""
        let was = rev
        applied = LiveApplied(rev: r, payload: payload, sig: env.sig ?? "", key: key, at: Date(), note: note)
        appliedManifest = m
        save()
        addLog(r, hold != nil ? "rolled back" : (r < was ? "reverted" : "applied"), note.isEmpty ? "Release \(r)" : note)
        applyEffects(accentWas: previousAccent)
        Task { let _: Ack? = try? await Api.shared.post("/api/live/report", json: ["rev": r, "status": "applied"]) }
    }

    private func applyEffects(accentWas: String?) {
        let hex = config.theme?.accent
        LiveTheme.accent = hex.flatMap(Self.color(hex:))
        if hex != accentWas { themeRev += 1 }
        objectWillChange.send()
    }

    // MARK: signature and key pinning

    private enum Check { case ok, bad(String), changed }

    private func verify(_ env: LiveEnvelope) -> Check {
        guard let payload = env.payload?.data(using: .utf8), let sig = env.sig.flatMap({ Data(base64Encoded: $0) }),
              let keyText = env.key, let keyData = Data(base64Encoded: keyText),
              let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return .bad("The server's update was incomplete.") }
        guard pk.isValidSignature(sig, for: payload) else { return .bad("The update's signature doesn't match. It was ignored.") }
        if let built = bundledKey() {
            keyState = .pinnedByApp
            return keyText == built ? .ok : .bad("The update isn't signed with the key built into this app. It was ignored.")
        }
        if let pinned = defaults.string(forKey: "dt.live.key") {
            if pinned == keyText { if keyState != .trusted { keyState = .trusted }; return .ok }
            return .changed
        }
        defaults.set(keyText, forKey: "dt.live.key"); keyState = .trusted    // first contact: remember this key
        return .ok
    }

    private func bundledKey() -> String? {
        guard let u = Bundle.main.url(forResource: "live-pubkey", withExtension: "txt"), let s = try? String(contentsOf: u, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t
    }
    private func pinnedKey() -> String? { bundledKey() ?? defaults.string(forKey: "dt.live.key") }

    private func fingerprint(of key: String?) -> String? {
        guard let key, let d = Data(base64Encoded: key) else { return nil }
        let hex = SHA256.hash(data: d).map { String(format: "%02X", $0) }.joined().prefix(16)
        return stride(from: 0, to: 16, by: 4).map { i -> String in
            let s = hex.index(hex.startIndex, offsetBy: i); return String(hex[s..<hex.index(s, offsetBy: 4)])
        }.joined(separator: " ")
    }
    func fingerprint(ofNew key: String) -> String { fingerprint(of: key) ?? key }

    // MARK: storage

    private struct Saved: Codable { var applied: LiveApplied?; var log: [LiveLogEntry] }
    private var fileURL: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Live", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("state.json")
    }
    private func save() { if let d = try? JSONEncoder().encode(Saved(applied: applied, log: Array(log.prefix(60)))) { try? d.write(to: fileURL, options: .atomic) } }
    private func load() {
        guard let d = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(Saved.self, from: d) else { return }
        log = s.log
        // what was applied last time is checked again before it is trusted (the file could have been altered)
        if let a = s.applied, let p = a.payload.data(using: .utf8), let sig = Data(base64Encoded: a.sig), let kd = Data(base64Encoded: a.key),
           let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: kd), pk.isValidSignature(sig, for: p),
           a.key == pinnedKey() || pinnedKey() == nil,
           let m = try? JSONDecoder().decode(LiveManifest.self, from: p) {
            applied = a; appliedManifest = m
            LiveTheme.accent = m.config?.theme?.accent.flatMap(Self.color(hex:))
        }
    }
    private func addLog(_ rev: Int, _ event: String, _ note: String) {
        log.insert(LiveLogEntry(rev: rev, event: event, note: note, at: Date()), at: 0)
        if log.count > 60 { log.removeLast(log.count - 60) }
        save()
    }

    static func color(hex: String) -> Color? {
        var h = hex.trimmingCharacters(in: .whitespaces); if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
}

struct LiveError: LocalizedError {
    let text: String
    init(_ t: String) { text = t }
    var errorDescription: String? { text }
}
struct Ack: Decodable { var ok: Bool? }
