import Foundation
import SwiftUI

/// Searches the repo apps without freezing the screen: the filtering runs off the main thread after a short pause in typing,
/// and only a few results are handed to the list at a time (more load as you scroll). Built for repos with 10,000+ apps.
@MainActor
final class AppSearcher: ObservableObject {
    static let pageSize = 10

    @Published private(set) var shown: [AppEntry] = []
    @Published private(set) var total = 0
    @Published private(set) var searching = false

    /// Fewer characters than this shows nothing (the Home screen waits for 2).
    var minChars = 0
    private var matches: [AppEntry] = []
    private var limit = AppSearcher.pageSize
    private var task: Task<Void, Never>?

    func update(query: String, apps: [AppEntry]) {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        limit = Self.pageSize
        if q.count < minChars {
            matches = []; total = 0; shown = []; searching = false
            return
        }
        searching = true
        task = Task { [weak self] in
            if !q.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }   // wait for a pause in typing
            if Task.isCancelled { return }
            let found = await Task.detached(priority: .userInitiated) { AppSearcher.filter(apps, q) }.value
            if Task.isCancelled { return }
            self?.apply(found)
        }
    }

    /// Shows the next page. The list calls this when its last row scrolls into view.
    func loadMore() {
        guard limit < matches.count else { return }
        limit += Self.pageSize
        shown = Array(matches.prefix(limit))
    }

    var hasMore: Bool { shown.count < total }

    private func apply(_ found: [AppEntry]) {
        matches = found
        total = found.count
        shown = Array(found.prefix(limit))
        searching = false
    }

    nonisolated static func filter(_ apps: [AppEntry], _ q: String) -> [AppEntry] {
        if q.isEmpty { return apps }
        var out: [AppEntry] = []
        for a in apps {
            if Task.isCancelled { return out }
            if a.key.contains(q) { out.append(a) }
        }
        return out
    }
}
