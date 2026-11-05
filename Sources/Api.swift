import Foundation
import SwiftUI

enum ApiError: LocalizedError {
    case bad, server(String, Int)
    var errorDescription: String? {
        switch self {
        case .bad: return "That address isn't valid."
        case .server(let m, _): return m
        }
    }
    var status: Int { if case .server(_, let s) = self { return s }; return 0 }
}

private struct ErrBody: Decodable { var error: String? }

/// Talks to the Decrypt.team server. The sign-in cookie lives in the shared cookie store, so a login done in the web sheet is used here too.
final class Api {
    static let shared = Api()

    var base: String {
        (UserDefaults.standard.string(forKey: "dt.server") ?? "https://decrypt.team").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    func request(_ method: String, _ path: String, json: Any? = nil, timeout: TimeInterval = 30) async throws -> Data {
        guard let u = URL(string: base + path), u.scheme == "https" else { throw ApiError.bad }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("1", forHTTPHeaderField: "x-dt")
        r.setValue(base, forHTTPHeaderField: "Origin")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: r)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            let msg = (try? JSONDecoder().decode(ErrBody.self, from: data))?.error
            throw ApiError.server(msg ?? "The server answered with error \(h.statusCode).", h.statusCode)
        }
        return data
    }

    func get<T: Decodable>(_ path: String, timeout: TimeInterval = 30) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await request("GET", path, timeout: timeout))
    }

    func post<T: Decodable>(_ path: String, json: Any? = nil) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await request("POST", path, json: json ?? [String: Any]()))
    }
}

// MARK: - Signed-in user

struct MeReply: Decodable {
    struct User: Decodable { var username: String?; var staff: Bool?; var beta: Bool?; var role: String?; var photoUrl: String? }
    var user: User?
}

struct TgStart: Decodable { var token: String; var url: String }
struct TgPoll: Decodable { var status: String; var step: String? }

enum LoginPhase: Equatable {
    case idle, opening, waiting(String), denied(String), failed(String)
}

@MainActor
final class Session: ObservableObject {
    @Published var username: String?
    @Published var beta = false
    @Published var staff = false
    /// "admin", "staff" or "member" — mirrors the server's role column (admin implies staff there too).
    @Published var role = "member"
    /// Relative or absolute URL for the signed-in person's Telegram profile photo; nil if none is cached yet.
    @Published var photoUrl: String?
    @Published var checked = false
    @Published var phase: LoginPhase = .idle
    /// True for the moment right after a Telegram login succeeds, so the app can show a one-screen
    /// "signed in as ..." reveal (photo, username, role) before dropping into the main app. Never persisted —
    /// a relaunch of an already-signed-in app goes straight in, this is only for the login moment itself.
    @Published var justSignedIn = false

    var signedIn: Bool { username != nil }
    /// Closed beta: only signed-in Decrypt.Team staff get past the onboarding screen.
    var allowed: Bool { signedIn && beta }
    private var loginTask: Task<Void, Never>?
    private var nudged = false

    /// The last answer from the server is remembered, so opening the app goes straight to the right screen
    /// and the check below only confirms it in the background.
    init() {
        let d = UserDefaults.standard
        if let name = d.string(forKey: "dt.me.name") {
            username = name
            beta = d.bool(forKey: "dt.me.beta")
            staff = d.bool(forKey: "dt.me.staff")
            role = d.string(forKey: "dt.me.role") ?? (staff ? "staff" : "member")
            photoUrl = d.string(forKey: "dt.me.photo")
            checked = true
        }
    }

    private func remember() {
        let d = UserDefaults.standard
        if let username {
            d.set(username, forKey: "dt.me.name"); d.set(beta, forKey: "dt.me.beta"); d.set(staff, forKey: "dt.me.staff")
            d.set(role, forKey: "dt.me.role")
            if let photoUrl { d.set(photoUrl, forKey: "dt.me.photo") } else { d.removeObject(forKey: "dt.me.photo") }
        } else {
            for k in ["dt.me.name", "dt.me.beta", "dt.me.staff", "dt.me.role", "dt.me.photo"] { d.removeObject(forKey: k) }
        }
    }

    func refresh() async {
        do {
            let me: MeReply = try await Api.shared.get("/api/auth/me", timeout: 8)
            username = me.user?.username
            beta = me.user?.beta ?? false
            staff = me.user?.staff ?? false
            role = me.user?.role ?? (staff ? "staff" : "member")
            photoUrl = me.user?.photoUrl
            remember()
        } catch {
            // no answer (offline, slow server): keep what we remembered; a stranger just sees the onboarding screen
            if case ApiError.server(_, let code) = error, code == 401 {
                username = nil; beta = false; staff = false; role = "member"; photoUrl = nil; remember()
            }
        }
        checked = true
    }

    /// Telegram login: the server makes a token, Telegram opens on the bot, and the app polls until the person confirms there.
    func loginWithTelegram(open: @escaping (URL) -> Void) {
        loginTask?.cancel()
        phase = .opening
        loginTask = Task { [weak self] in
            guard let self else { return }
            do {
                let st: TgStart = try await Api.shared.post("/api/auth/telegram/start", json: ["app": true])
                guard let url = URL(string: st.url), url.host == "t.me" else { throw ApiError.bad }
                self.phase = .waiting("Confirm the login in Telegram")
                open(url)
                let until = Date().addingTimeInterval(300)
                while Date() < until, !Task.isCancelled {
                    // wait about 2 seconds, or less when the app was just reopened from Telegram
                    var waited = 0
                    while waited < 4 && !self.nudged { try await Task.sleep(nanoseconds: 500_000_000); waited += 1 }
                    self.nudged = false
                    let q = st.token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? st.token
                    let p: TgPoll = try await Api.shared.get("/api/auth/telegram/poll?token=" + q)
                    if p.status == "done" {
                        await self.refresh()
                        if self.allowed { self.justSignedIn = true }
                        self.phase = self.allowed ? .idle : .denied("This account isn't on the Decrypt.Team staff list.")
                        return
                    }
                    if p.status == "expired" { self.phase = .failed("The login link expired. Try again."); return }
                    if p.step == "confirm" { self.phase = .waiting("Tap Confirm login in the bot chat") }
                }
                if !Task.isCancelled { self.phase = .failed("Timed out. Try again.") }
            } catch is CancellationError {
            } catch let e as ApiError where e.status == 403 {
                self.phase = .denied(e.localizedDescription)
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Called when the app comes back to the front: check the Telegram login right away.
    func nudge() { nudged = true }

    func cancelLogin() { loginTask?.cancel(); phase = .idle }

    func signOut() async {
        _ = try? await Api.shared.request("POST", "/api/auth/logout", json: [String: Any]())
        for c in HTTPCookieStorage.shared.cookies ?? [] { HTTPCookieStorage.shared.deleteCookie(c) }
        username = nil; beta = false; staff = false; role = "member"; photoUrl = nil; phase = .idle; justSignedIn = false
        remember()
    }

    /// Absolute URL for `photoUrl` (the server returns it relative), or nil if there's nothing to show.
    var photoURL: URL? {
        guard let photoUrl, !photoUrl.isEmpty else { return nil }
        if photoUrl.hasPrefix("http") { return URL(string: photoUrl) }
        return URL(string: Api.shared.base + photoUrl)
    }
}

// MARK: - Lenient values

struct Flex: Decodable {
    let text: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { text = s }
        else if let b = try? c.decode(Bool.self) { text = b ? "true" : "false" }
        else if let i = try? c.decode(Int64.self) { text = String(i) }
        else if let d = try? c.decode(Double.self) { text = String(d) }
        else { text = "" }
    }
}

func formatCount(_ n: Int64) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? String(n)
}
