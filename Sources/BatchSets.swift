import Foundation

/// A named group of imported dylibs ("my usual tweaks") that switches the Batch list to exactly those.
struct BatchDylibSet: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var dylibIDs: [String]
}

@MainActor
final class BatchSetStore: ObservableObject {
    static let shared = BatchSetStore()
    @Published private(set) var sets: [BatchDylibSet] = []
    private let key = "dt.batch.sets"

    private init() {
        if let d = UserDefaults.standard.data(forKey: key), let l = try? JSONDecoder().decode([BatchDylibSet].self, from: d) { sets = l }
    }

    func saveCurrent(name: String, from dylibs: BatchDylibStore) {
        let ids = dylibs.items.filter { $0.enabled }.map(\.id)
        guard !ids.isEmpty else { return }
        sets.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        sets.insert(BatchDylibSet(name: name, dylibIDs: ids), at: 0)
        persist()
    }

    func apply(_ s: BatchDylibSet, to dylibs: BatchDylibStore) {
        let want = Set(s.dylibIDs)
        for d in dylibs.items where d.enabled != want.contains(d.id) { var n = d; n.enabled = want.contains(d.id); dylibs.update(n) }
    }

    func delete(_ s: BatchDylibSet) { sets.removeAll { $0.id == s.id }; persist() }

    private func persist() { if let d = try? JSONEncoder().encode(sets) { UserDefaults.standard.set(d, forKey: key) } }
}
