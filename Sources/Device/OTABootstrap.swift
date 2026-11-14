import Foundation

/// Keeps the tetherless.dev public SSL pack installed so OTA works without a
/// Settings visit. Runs on launch and whenever the app becomes active.
enum OTABootstrap {
    private static var lastAttempt: Date?
    private static let minInterval: TimeInterval = 60

    /// Force public mode and pull https://tetherless.dev/pack.json into the cache.
    @MainActor
    @discardableResult
    static func ensurePublicPack(force: Bool = false) async -> ZefvCert.Meta? {
        if !force, let last = lastAttempt, Date().timeIntervalSince(last) < minInterval {
            return ZefvCert.meta
        }
        lastAttempt = Date()
        ServerConfig.setCertMode("public")
        let meta = await ZefvCert.installPublicPack()
        if meta != nil {
            ActivityStore.shared.log("OTA", "installed tetherless.dev SSL pack for \(ServerConfig.installHost)")
        }
        return meta
    }
}
