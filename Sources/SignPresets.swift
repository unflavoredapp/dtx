import Foundation

/// A saved combination of build options, applied to the sign page with one tap.
struct SignPreset: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var flags: [String: Bool] = [:]
    var plist: [String: String] = [:]
    var injectPath = "@executable_path"
    var injectFolder = "/"
    var thin = false
}

enum SignPresetKeys {
    /// Every on/off option the sign page offers, by a stable name.
    static let all: [(String, WritableKeyPath<SignOptions, Bool>)] = [
        ("disableFileSharing", \.disableFileSharing), ("forcePortrait", \.forcePortrait), ("skipIPad", \.skipIPad), ("disableATS", \.disableATS),
        ("stripSCInfo", \.stripSCInfo), ("stripPrivacyManifests", \.stripPrivacyManifests), ("stripWatchApps", \.stripWatchApps),
        ("stripExtensions", \.stripExtensions), ("removeURLSchemes", \.removeURLSchemes), ("stripBitcode", \.stripBitcode),
        ("stripDebugSymbols", \.stripDebugSymbols), ("autoFixEntitlements", \.autoFixEntitlements), ("disablePush", \.disablePush),
        ("disableAppGroups", \.disableAppGroups), ("disableiCloud", \.disableiCloud), ("disableSiri", \.disableSiri),
        ("disableBackgroundModes", \.disableBackgroundModes),
    ]
}

@MainActor
final class SignPresetStore: ObservableObject {
    static let shared = SignPresetStore()
    @Published private(set) var items: [SignPreset] = []
    private let key = "dt.sign.presets"

    private init() {
        if let d = UserDefaults.standard.data(forKey: key), let l = try? JSONDecoder().decode([SignPreset].self, from: d) { items = l }
    }

    func save(name: String, from o: SignOptions, thin: Bool) {
        var p = SignPreset(name: name)
        for (k, path) in SignPresetKeys.all where o[keyPath: path] { p.flags[k] = true }
        p.plist = o.plistSet; p.injectPath = o.injectPath; p.injectFolder = o.injectFolder; p.thin = thin
        items.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        items.insert(p, at: 0)
        persist()
    }

    func apply(_ p: SignPreset, to o: inout SignOptions) {
        for (k, path) in SignPresetKeys.all { o[keyPath: path] = p.flags[k] ?? false }
        o.plistSet = p.plist; o.injectPath = p.injectPath; o.injectFolder = p.injectFolder
    }

    func delete(_ p: SignPreset) { items.removeAll { $0.id == p.id }; persist() }

    private func persist() { if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) } }
}
