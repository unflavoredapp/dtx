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

    /// The footprint written as chat-style markdown: a heading per day, a bullet per action.
    func markdown(matching query: String = "") -> String {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? entries : entries.filter { ($0.title + " " + ($0.detail ?? "")).lowercased().contains(q) }
        guard !list.isEmpty else {
            return q.isEmpty ? "_Nothing yet. Tap anything above and it shows up here._" : "_No activity matches._"
        }
        let cal = Calendar.current
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "EEEE, d MMM"
        let timeFmt = DateFormatter(); timeFmt.timeStyle = .short; timeFmt.dateStyle = .none
        var out: [String] = []
        var lastDay: Date?
        for e in list {
            let day = cal.startOfDay(for: e.date)
            if day != lastDay {
                let name = cal.isDateInToday(e.date) ? "Today" : cal.isDateInYesterday(e.date) ? "Yesterday" : dayFmt.string(from: e.date)
                out.append((out.isEmpty ? "" : "\n") + "### " + name + "\n")
                lastDay = day
            }
            var line = "- **" + e.title + "**"
            if let d = e.detail, !d.isEmpty { line += " — " + d }
            line += " · `" + timeFmt.string(from: e.date) + "`"
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}
