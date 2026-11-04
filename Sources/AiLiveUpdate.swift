import SwiftUI

// MARK: - live_update tool: lets the chat model read and drive the app's Live Update system

/// The model can read the Live Update state and ask for a sync. It can never trust a signing key, apply a held
/// update or roll back: those stay with the person, in the Update Center.
enum AiLiveTool {
    static let name = "live_update"

    static let schema: [String: Any] = [
        "type": "function",
        "function": [
            "name": name,
            "description": "Reads or syncs the app's own Live Update system (signed releases from the server: live configuration, plugins, recipes, native app builds). Use it when the person asks about updates, what version they're on, why an update is held, or to check for / pull the newest release. It cannot confirm a signing key or force an update; for that tell the person to open the Update Center from the card.",
            "parameters": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["status", "sync", "resume"],
                               "description": "status = report where things stand; sync = check the server now and apply what is allowed; resume = lift a rollback hold and sync."],
                ],
                "required": ["action"],
            ] as [String: Any],
        ] as [String: Any],
    ]

    static func action(_ arguments: String) -> String {
        guard let d = arguments.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "status" }
        return ((o["action"] as? String) ?? "status").lowercased()
    }

    @MainActor
    static func run(arguments: String) async -> String {
        let live = LiveSync.shared
        switch action(arguments) {
        case "sync": await live.sync()
        case "resume": await live.resume()
        default: break
        }
        return report(live)
    }

    @MainActor
    static func report(_ live: LiveSync) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        var l: [String] = []
        l.append("Runtime \(Runtime.version) build \(Runtime.build). Channel: \(live.channel). Auto-sync: \(live.autoSync ? "on" : "off").")
        l.append(live.rev == 0 ? "Live release: none (the app is using its built-in settings)." : "Live release applied: #\(live.rev)\((live.applied?.note ?? "").isEmpty ? "" : " — " + (live.applied?.note ?? "")).")
        l.append("Last sync: \(live.lastSync.map { f.string(from: $0) } ?? "never").")
        if let m = live.manifest?.rev { l.append("Newest release the server offers: #\(m)\(live.updateAvailable ? " (not applied yet)" : "").") }
        switch live.keyState {
        case .unenrolled: l.append("HELD: this is the first sync, so the person must confirm the server's signing key fingerprint in the Update Center before anything is applied.")
        case .changed: l.append("HELD: the server is signing with a NEW key. The person must check and confirm it in the Update Center. Do not tell them to just accept it.")
        case .pinnedByApp: l.append("Signing key: built into this app.")
        case .trusted: l.append("Signing key: trusted.")
        case .none: break
        }
        if let h = live.holdRev { l.append("Rolled back and held at release #\(h): no automatic upgrades until updates are resumed.") }
        if live.needsNative { l.append("A release is waiting for a newer app build.") }
        if live.nativeNewer, let n = live.native?.build { l.append("A newer native app (build \(n)) is announced; installing it is done by hand.") }
        l.append("Plugins: \(live.plugins.count). Recipes: \(live.recipes.count).")
        if !live.lastError.isEmpty { l.append("Last error: \(live.lastError)") }
        let recent = live.log.prefix(4).map { "- \($0.event): \($0.note)" }
        if !recent.isEmpty { l.append("Recent history:\n" + recent.joined(separator: "\n")) }
        return l.joined(separator: "\n")
    }
}

// MARK: - Status card in the chat

struct AiLiveCard: View {
    @ObservedObject private var live = LiveSync.shared
    @State private var showCenter = false

    private var held: String? {
        switch live.keyState {
        case .unenrolled: return "Confirm the server's signing key before anything is applied."
        case .changed: return "The signing key changed. Check it before applying."
        default: return live.holdRev.map { "Held at release #\($0). Not upgrading by itself." }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Color.dtAccent)
                Text("Live Update").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Spacer(minLength: 0)
                Text(live.rev == 0 ? "Built-in" : "Release #\(live.rev)").font(.caption.bold()).foregroundStyle(Color.dtAccent)
            }
            Text("Runtime \(Runtime.version) · build \(Runtime.build) · \(live.channel)").font(.footnote).foregroundStyle(.secondary)
            if let h = held {
                Label(h, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
            } else if live.updateAvailable, let r = live.manifest?.rev {
                Label("Release #\(r) is available.", systemImage: "arrow.down.circle.fill").font(.footnote).foregroundStyle(Color.dtAccent)
            }
            if !live.lastError.isEmpty { Text(live.lastError).font(.caption).foregroundStyle(.red).lineLimit(3) }
            HStack(spacing: 8) {
                Button { Task { await live.sync() } } label: {
                    HStack(spacing: 6) { if live.syncing { ProgressView().scaleEffect(0.7) }; Text(live.syncing ? "Syncing…" : "Sync now") }
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.dtOnAccent)
                        .padding(.horizontal, 16).padding(.vertical, 9).background(Capsule().fill(Color.dtAccent))
                }.disabled(live.syncing)
                Button { showCenter = true } label: {
                    Text(held != nil && live.holdRev == nil ? "Review key" : "Update Center").font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 9).aiGlass(Capsule())
                }
                if live.holdRev != nil {
                    Button { Task { await live.resume() } } label: {
                        Text("Resume").font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 9).aiGlass(Capsule())
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.115)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5))
        .sheet(isPresented: $showCenter) { UpdateCenterView() }
    }
}
