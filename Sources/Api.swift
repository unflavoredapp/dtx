import Foundation
import SwiftUI
import WebKit

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
    struct User: Decodable { var username: String? }
    var user: User?
}

@MainActor
final class Session: ObservableObject {
    @Published var username: String?
    @Published var showLogin = false

    var signedIn: Bool { username != nil }

    func refresh() async {
        let me: MeReply? = try? await Api.shared.get("/api/auth/me")
        username = me?.user?.username
    }

    /// Copies the sign-in made in the web sheet into the cookie store the app's own requests use.
    func syncCookies() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        for c in cookies { HTTPCookieStorage.shared.setCookie(c) }
        await refresh()
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
