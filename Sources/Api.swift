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

    func request(_ method: String, _ path: String, json: Any? = nil) async throws -> Data {
        guard let u = URL(string: base + path), u.scheme == "https" else { throw ApiError.bad }
        var r = URLRequest(url: u, timeoutInterval: 30)
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

    func get<T: Decodable>(_ path: String) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await request("GET", path))
    }

    func post<T: Decodable>(_ path: String, json: Any? = nil) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await request("POST", path, json: json ?? [String: Any]()))
    }
}

// MARK: - Signed-in user

struct MeReply: Decodable {
    struct User: Decodable { var username: String?; var staff: Bool?; var beta: Bool? }
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
    @Published var checked = false
    @Published var phase: LoginPhase = .idle

    var signedIn: Bool { username != nil }
    /// Closed beta: only signed-in Decrypt.Team staff get past the onboarding screen.
    var allowed: Bool { signedIn && beta }
    private var loginTask: Task<Void, Never>?
    private var nudged = false

    func refresh() async {
        let me: MeReply? = try? await Api.shared.get("/api/auth/me")
        username = me?.user?.username
        beta = me?.user?.beta ?? false
        staff = me?.user?.staff ?? false
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
        username = nil; beta = false; phase = .idle
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
