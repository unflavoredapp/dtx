import SwiftUI

/// One thing the person did in the app (a sidebar tap, an imported certificate, ...).
struct ActivityEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var title: String
    var detail: String?
}

/// The person's footprint: every sidebar action is logged here, newest first, and kept on this device.
@MainActor
final class ActivityStore: ObservableObject {
    static let shared = ActivityStore()
    private let key = "dt.activity.v1"
    private let cap = 300

    @Published private(set) var entries: [ActivityEntry] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([ActivityEntry].self, from: data) {
            entries = list
        }
    }

    func log(_ title: String, _ detail: String? = nil) {
        entries.insert(ActivityEntry(date: Date(), title: title, detail: detail), at: 0)
        if entries.count > cap { entries.removeLast(entries.count - cap) }
        save()
    }

    func clear() { entries = []; save() }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// The footprint written as chat-style markdown: a summary, then a heading per day with each action and its details.
    func markdown(matching query: String = "") -> String {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? entries : entries.filter { ($0.title + " " + ($0.detail ?? "")).lowercased().contains(q) }
        guard !list.isEmpty else {
            return q.isEmpty ? "_Nothing yet. Tap anything above and it shows up here._" : "_No activity matches._"
        }
        let cal = Calendar.current
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "EEEE, d MMM"
        let timeFmt = DateFormatter(); timeFmt.timeStyle = .short; timeFmt.dateStyle = .none

        // summary
        var counts: [String: Int] = [:]
        for e in list { counts[e.title, default: 0] += 1 }
        let days = Set(list.map { cal.startOfDay(for: $0.date) }).count
        let top = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(3)
            .map { "**\($0.key)** ×\($0.value)" }.joined(separator: " · ")
        var out: [String] = [
            "> **\(list.count) action\(list.count == 1 ? "" : "s")** over \(days) day\(days == 1 ? "" : "s")",
            "> Most used: " + top,
            "> Last: **\(list[0].title)** at `\(timeFmt.string(from: list[0].date))`",
            ""
        ]

        // one section per day
        var i = 0
        while i < list.count {
            let day = cal.startOfDay(for: list[i].date)
            var group: [ActivityEntry] = []
            while i < list.count, cal.startOfDay(for: list[i].date) == day { group.append(list[i]); i += 1 }
            let name = cal.isDateInToday(day) ? "Today" : cal.isDateInYesterday(day) ? "Yesterday" : dayFmt.string(from: day)
            out.append("### " + name)
            out.append("_\(group.count) action\(group.count == 1 ? "" : "s")_")
            out.append("")
            for e in group {
                out.append("- **" + e.title + "** `" + timeFmt.string(from: e.date) + "`")
                if let d = e.detail, !d.isEmpty { out.append("  - " + d) }
            }
            out.append("")
            out.append("---")
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}
