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
extension LiveConfig {
    /// Everything a release can set is checked here before it is used: sizes, characters and shapes. Anything odd is dropped, not repaired.
    func sanitized() -> LiveConfig {
        func ident(_ s: String, _ n: Int = 60) -> Bool { !s.isEmpty && s.count <= n && s.range(of: "^[A-Za-z0-9_.\\-]+$", options: .regularExpression) != nil }
        func cut(_ s: String, _ n: Int) -> String { String(s.prefix(n)) }
        var c = LiveConfig()
        c.flags = flags.map { Dictionary(uniqueKeysWithValues: $0.filter { ident($0.key, 40) }.prefix(50).map { ($0.key, $0.value) }) }
        c.auto = auto.map { Dictionary(uniqueKeysWithValues: $0.filter { ident($0.key) }.prefix(100).map { ($0.key, $0.value) }) }
        c.hide = hide.map { Array($0.filter { ident($0) }.prefix(100)) }
        c.order = order.map { Array($0.filter { ident($0) }.prefix(100)) }
        if let a = theme?.accent, LiveSync.color(hex: a) != nil { c.theme = Theme(accent: a) }
        if let b = banner, ident(b.id, 40), !b.title.isEmpty {
            let u = b.url.flatMap { URL(string: $0)?.scheme == "https" && $0.count < 400 ? $0 : nil }
            c.banner = LiveBannerInfo(id: b.id, title: cut(b.title, 80), text: cut(b.text, 400), url: u)
        }
        c.experimental = experimental.map { Array($0.filter { ident($0.id, 40) && !$0.title.isEmpty }.prefix(10).map { LiveExperiment(id: $0.id, title: cut($0.title, 80), detail: $0.detail.map { cut($0, 200) }) }) }
        return c
    }
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

    enum KeyState: Equatable { case none, pinnedByApp, trusted, unenrolled(String), changed(String) }

    @Published private(set) var applied: LiveApplied?
    @Published private(set) var lastGood: LiveApplied?           // the last release that opened cleanly; the app falls back to it if a new one doesn't
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
        checkTrial()
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

    /// Where the manifest and the tool lists the app actually loaded disagree.
    func reconcile(server: [Tool], recipes recipeTools: [Tool]) -> [String] {
        guard manifest != nil else { return [] }
        var out: [String] = []
        let serverIDs = Dictionary(uniqueKeysWithValues: server.map { ($0.id, $0) })
        for p in plugins {
            guard let t = serverIDs["server-" + p.id] else { if !server.isEmpty { out.append("\(p.name ?? p.id) is in the manifest but the server's tool list doesn't have it.") }; continue }
            if let v = p.version, !v.isEmpty, !t.version.isEmpty, v != t.version { out.append("\(t.name): manifest says v\(v), the tool list says v\(t.version).") }
        }
        let manifestIDs = Set(plugins.map { "server-" + $0.id })
        for t in server where !manifestIDs.contains(t.id) { out.append("\(t.name) is on the server but not in the manifest.") }
        let recipeIDs = Set(recipeTools.map(\.id)), manifestRecipes = Set(recipes.map { "recipe-" + $0.id })
        for r in recipes where !recipeIDs.contains("recipe-" + r.id) && !recipeTools.isEmpty { out.append("Recipe \(r.name ?? r.id) is in the manifest but wasn't downloaded.") }
        for t in recipeTools where !manifestRecipes.contains(t.id) { out.append("Recipe \(t.name) was downloaded but isn't in the manifest.") }
        return Array(out.prefix(8))
    }

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
            if let bad = defaults.object(forKey: "dt.live.failreport") as? Int {
                let _: Ack? = try? await Api.shared.post("/api/live/report", json: ["rev": bad, "status": "failed"]); defaults.removeObject(forKey: "dt.live.failreport")
            }
            try process(env, hold: hold ? rev : nil, expect: rev)
        } catch let e as ApiError where e.status == 404 {
            lastError = "This server has no live sync yet."
        } catch {
            lastError = error.localizedDescription
        }
    }

    func rollback(to rev: Int) async { await sync(rev: rev, hold: true) }

    func resume() async { holdRev = nil; defaults.removeObject(forKey: "dt.live.hold"); await sync() }

    /// The person looked at the fingerprint and agrees with it (first sync, or a changed key). Only then is the key remembered.
    func trustPendingKey() {
        let key: String
        switch keyState { case .changed(let k), .unenrolled(let k): key = k; default: return }
        guard let env = pending, env.key == key else { return }
        defaults.set(key, forKey: "dt.live.key"); keyState = .trusted
        addLog(0, "key trusted", "Signing key \(fingerprint(ofNew: key)) was confirmed.")
        do { try process(env, hold: nil, expect: nil) } catch { lastError = error.localizedDescription }
        pending = nil
    }

    private func process(_ env: LiveEnvelope, hold: Int?, expect: Int?) throws {
        guard let payload = env.payload, let key = env.key else { throw LiveError("The server's update was incomplete.") }
        switch verify(env) {
        case .bad(let why): addLog(0, "rejected", why); throw LiveError(why)
        case .enroll:
            pending = env; keyState = .unenrolled(key)
            addLog(0, "held", "Confirm the signing key in the Update Center before anything is applied.")
            throw LiveError("First sync: confirm the server's signing key in the Update Center. Nothing was applied.")
        case .changed:
            pending = env; keyState = .changed(key)
            addLog(0, "held", "The signing key changed. Confirm it in the Update Center.")
            throw LiveError("The server is signing with a new key. Check it in the Update Center before applying anything.")
        case .ok: break
        }
        guard let m = Self.decode(payload) else { throw LiveError("The update couldn't be read.") }
        if let ch = m.channel, ch != channel { addLog(m.rev ?? 0, "rejected", "It was for the \(ch) channel."); throw LiveError("The server answered for the \(ch) channel, not \(channel). It was ignored.") }
        if let want = expect, (m.rev ?? -1) != want { addLog(m.rev ?? 0, "rejected", "Asked for release \(want), got \(m.rev ?? 0)."); throw LiveError("The server didn't return release \(want). Nothing changed.") }
        guard let issued = m.issued.flatMap(Self.date(iso:)), abs(issued.timeIntervalSinceNow) < 24 * 3600 else {
            addLog(m.rev ?? 0, "rejected", "Stale or undated update."); throw LiveError("The update is too old or has no valid date (is this phone's clock right?). It was ignored.")
        }
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
        if defaults.object(forKey: "dt.live.trial") == nil, let cur = applied { lastGood = cur }     // keep the last release that is known to work
        defaults.set(r, forKey: "dt.live.trial"); defaults.set(0, forKey: "dt.live.trial.n")
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

    private enum Check { case ok, bad(String), enroll, changed }

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
        return .enroll                  // nothing is trusted yet: the person has to confirm the fingerprint first
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

    private struct Saved: Codable { var applied: LiveApplied?; var lastGood: LiveApplied?; var log: [LiveLogEntry] }
    private var fileURL: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Live", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("state.json")
    }
    private func save() { if let d = try? JSONEncoder().encode(Saved(applied: applied, lastGood: lastGood, log: Array(log.prefix(60)))) { try? d.write(to: fileURL, options: .atomic) } }
    /// A saved release is only believed again if its signature is valid AND it was signed by the key this phone trusts.
    private func restore(_ a: LiveApplied?) -> (LiveApplied, LiveManifest)? {
        guard let a, let p = a.payload.data(using: .utf8), let sig = Data(base64Encoded: a.sig), let kd = Data(base64Encoded: a.key),
              let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: kd), pk.isValidSignature(sig, for: p),
              let trusted = pinnedKey(), a.key == trusted, let m = Self.decode(a.payload) else { return nil }
        return (a, m)
    }
    private func load() {
        guard let d = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(Saved.self, from: d) else { return }
        log = s.log
        if let (a, m) = restore(s.applied) { applied = a; appliedManifest = m; LiveTheme.accent = m.config?.theme?.accent.flatMap(Self.color(hex:)) }
        lastGood = restore(s.lastGood)?.0
    }

    /// A new release gets a few launches to prove itself. If the app keeps failing to stay open, it goes back to the last good release.
    private func checkTrial() {
        guard let trial = defaults.object(forKey: "dt.live.trial") as? Int else { return }
        let n = defaults.integer(forKey: "dt.live.trial.n") + 1
        defaults.set(n, forKey: "dt.live.trial.n")
        guard n >= 3 else { return }
        defaults.removeObject(forKey: "dt.live.trial"); defaults.removeObject(forKey: "dt.live.trial.n")
        if let (a, m) = restore(lastGood) { applied = a; appliedManifest = m } else { applied = nil; appliedManifest = nil }
        LiveTheme.accent = appliedManifest?.config?.theme?.accent.flatMap(Self.color(hex:))
        holdRev = applied?.rev ?? 0; defaults.set(holdRev, forKey: "dt.live.hold")
        defaults.set(trial, forKey: "dt.live.failreport")
        addLog(trial, "reverted", "The app didn't stay open with release \(trial), so it went back to " + (applied.map { "release \($0.rev)" } ?? "the built-in settings") + ".")
    }

    /// Called a few seconds after the main screen is up: the release worked.
    func confirmHealthy() {
        guard defaults.object(forKey: "dt.live.trial") != nil else { return }
        defaults.removeObject(forKey: "dt.live.trial"); defaults.removeObject(forKey: "dt.live.trial.n")
        lastGood = applied; save()
    }

    private func addLog(_ rev: Int, _ event: String, _ note: String) {
        log.insert(LiveLogEntry(rev: rev, event: event, note: note, at: Date()), at: 0)
        if log.count > 60 { log.removeLast(log.count - 60) }
        save()
    }

    static func decode(_ payload: String) -> LiveManifest? {
        guard let d = payload.data(using: .utf8), var m = try? JSONDecoder().decode(LiveManifest.self, from: d) else { return nil }
        m.config = m.config?.sanitized()
        m.plugins = m.plugins.map { Array($0.prefix(200)) }; m.recipes = m.recipes.map { Array($0.prefix(200)) }; m.history = m.history.map { Array($0.prefix(30)) }
        return m
    }
    static func date(iso: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
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
