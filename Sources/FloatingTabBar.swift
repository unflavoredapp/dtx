import SwiftUI

/// The tab bar at the bottom: five equal tabs on one glass capsule. Home sits in the middle.
struct FloatingTabBar: View {
    @EnvironmentObject var store: RepoStore

    /// The signature symbol (iOS 17 and later); older systems get a pencil.
    private static let signedIcon = UIImage(systemName: "signature") != nil ? "signature" : "pencil.and.scribble"

    var body: some View {
        HStack(spacing: 0) {
            item("Browse", "circle.grid.3x3.fill", on: store.tab == .repos) { store.tab = .repos }
            item("Library", "square.grid.2x2.fill", on: store.tab == .search) { store.tab = .search }
            item("Home", "house.fill", on: store.tab == .home) { store.tab = .home }
            item("Signed", Self.signedIcon, on: store.tab == .signed) { store.tab = .signed }
            item("Settings", "gearshape.fill", on: store.tab == .settings) { store.tab = .settings }
        }
        .padding(.horizontal, 6).padding(.vertical, 10)
        .glassPanel(radius: 34)
        .padding(.horizontal, 14).padding(.bottom, 4)
    }

    private func item(_ title: String, _ icon: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 22)).frame(height: 28)
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(on ? Color.dtAccent : Color.white.opacity(0.55))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}
