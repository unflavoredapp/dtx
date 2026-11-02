import Foundation
import SwiftUI

/// One finished build, remembered on this phone so the Signed tab can list it.
struct SignedEntry: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var bid: String
    var version: String
    var icon: String?
    var date: Date
    var link: String
    var size: Int64
}

@MainActor
final class SignedStore: ObservableObject {
    static let shared = SignedStore()
    private let key = "dt.signed"
    @Published private(set) var items: [SignedEntry] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([SignedEntry].self, from: data) { items = list }
    }

    func add(_ e: SignedEntry) {
        items.removeAll { $0.id == e.id }
        items.insert(e, at: 0)
        if items.count > 200 { items = Array(items.prefix(200)) }
        save()
    }

    func remove(_ e: SignedEntry) { items.removeAll { $0.id == e.id }; save() }
    func clear() { items = []; save() }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// "just now", "6m ago", "3h ago", "2d ago"
func shortAgo(_ date: Date) -> String {
    let s = max(0, Int(Date().timeIntervalSince(date)))
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60)m ago" }
    if s < 86400 { return "\(s / 3600)h ago" }
    return "\(s / 86400)d ago"
}
