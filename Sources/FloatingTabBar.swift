import SwiftUI

/// The tab bar that floats above the content: a glowing glass capsule with a raised + button in the middle.
struct FloatingTabBar: View {
    @EnvironmentObject var store: RepoStore

    var body: some View {
        HStack(spacing: 0) {
            item(.home, "Home", "house.fill")
            item(.search, "Apps", "square.grid.2x2.fill")
            Button { store.showQuickBuild = true } label: {
                Image(systemName: "plus").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 62, height: 54)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(LinearGradient(colors: [Color.dtAccent, Color(red: 0.93, green: 0.38, blue: 0.04)], startPoint: .top, endPoint: .bottom)))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.35), lineWidth: 1))
                    .shadow(color: Color.dtAccent.opacity(0.65), radius: 12)
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Start a build")
            item(.repos, "Repos", "square.stack.3d.up.fill")
            item(.settings, "Settings", "gearshape.fill")
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .glowCapsule(strong: true)
        .padding(.horizontal, 12).padding(.bottom, 4)
    }

    private func item(_ tab: AppTab, _ title: String, _ icon: String) -> some View {
        Button { store.tab = tab } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 22))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(store.tab == tab ? Color.dtAccent : Color.white.opacity(0.55))
            .shadow(color: store.tab == tab ? Color.dtAccent.opacity(0.7) : .clear, radius: 8)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}
