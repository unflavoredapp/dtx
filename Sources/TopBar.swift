import SwiftUI

/// The bar at the top of every main screen: a glass panel with the logo, the screen's title, search and build buttons,
/// and your account on a second row.
struct TopBar: View {
    @EnvironmentObject var store: RepoStore
    @EnvironmentObject var session: Session
    /// nil shows the Decrypt.Team name; any other text is the screen's title.
    var title: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image("Logo").resizable().frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Spacer(minLength: 0)
                Group {
                    if let title { Text(title).foregroundColor(.white) }
                    else { Text("Decrypt.").foregroundColor(.white) + Text("Team").foregroundColor(.dtAccent) }
                }
                .font(.system(size: 22, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Button { store.tab = .search } label: { Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .semibold)) }
                    .accessibilityLabel("Search apps")
                Button { store.showQuickBuild = true } label: { Image(systemName: "lock.fill").font(.system(size: 20, weight: .semibold)) }
                    .accessibilityLabel("Start a build")
            }
            .foregroundStyle(Color.dtAccent)
            .padding(.horizontal, 6)

            HStack {
                Spacer()
                Menu {
                    Text("Signed in as " + (session.username ?? ""))
                    Button("Sign out", role: .destructive) { Task { await session.signOut() } }
                } label: {
                    HStack(spacing: 8) {
                        Text(String((session.username ?? "?").prefix(1)).uppercased())
                            .font(.system(size: 15, weight: .heavy)).foregroundStyle(.black)
                            .frame(width: 34, height: 34).background(Circle().fill(Color.dtAccent))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(session.username ?? "Account").font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.dtAccent).lineLimit(1).frame(maxWidth: 130, alignment: .leading)
                            Text(session.staff ? "STAFF" : "BETA").font(.system(size: 10, weight: .heavy, design: .monospaced)).foregroundStyle(Color.dtGreen)
                        }
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.05)))
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 8)
        .glassPanel(radius: 30)
    }
}

extension View {
    /// Puts the shared top bar above a screen and hides the system navigation bar. Pushed screens keep their own.
    func withTopBar(_ title: String? = nil) -> some View {
        self
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { TopBar(title: title).padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 6) }
    }
}
