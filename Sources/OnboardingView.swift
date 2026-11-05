import SwiftUI

/// First screen of the app: one screen, Telegram sign-in. Closed beta for Decrypt.Team staff.
struct OnboardingView: View {
    @EnvironmentObject var session: Session
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 16) {
                Spacer()
                Image("Logo").resizable().frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.dtLine))
                Text("Decrypt.Team").font(.largeTitle.bold())
                Pill(text: "CLOSED BETA", tone: .dtAccent)
                Text("iOS app discovery and decryption tools. Sign in with the Telegram account that's on the Decrypt.Team staff list.")
                    .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 4)
                status
                Spacer()
                Button(action: start) {
                    HStack(spacing: 10) {
                        if busy { ProgressView().tint(.white) } else { Image(systemName: "paperplane.fill") }
                        Text(busy ? "Waiting for Telegram…" : "Sign in with Telegram").font(.headline)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(Color(red: 0.16, green: 0.62, blue: 0.86))
                .disabled(busy)
                if busy {
                    Button("Cancel") { session.cancelLogin() }.font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("Telegram opens on our bot. Tap Confirm login, then come back here.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private var busy: Bool {
        switch session.phase { case .opening, .waiting: return true; default: return false }
    }

    @ViewBuilder private var status: some View {
        switch session.phase {
        case .waiting(let m): Label(m, systemImage: "clock").font(.subheadline).foregroundStyle(Color.dtAccent)
        case .denied(let m):
            Label(m, systemImage: "lock.fill").font(.subheadline).foregroundStyle(Color.red)
                .multilineTextAlignment(.center).card()
        case .failed(let m):
            Label(m, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(Color.red)
                .multilineTextAlignment(.center)
        default: EmptyView()
        }
    }

    private func start() {
        session.loginWithTelegram { url in openURL(url) }
    }
}

/// Shown once, right after a Telegram login succeeds (`session.justSignedIn`): their Telegram photo, username
/// and role, before the app drops into the real home screen. Tapping Continue dismisses it for this session.
struct WelcomeView: View {
    @EnvironmentObject var session: Session

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 18) {
                Spacer()
                avatar
                VStack(spacing: 8) {
                    Text(session.username ?? "").font(.title2.bold())
                    Pill(text: roleLabel, tone: roleTone)
                }
                limits
                Spacer()
                Button("Continue") { session.justSignedIn = false }
                    .font(.headline)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .buttonStyle(AccentButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .transition(.opacity)
    }

    /// Ai-Decrypt's real per-role entitlements — the same char caps and tool-call round cap the app and
    /// server already enforce (AiDecryptChatView's maxLoops, aiedit.js's OPTIMIZE_CTX_CHARS / elevated message
    /// cap), shown here in approximate tokens (chars ÷ 4) so they read the way a token budget normally does.
    private var limits: some View {
        VStack(spacing: 10) {
            limitRow("text.bubble", "Per message", elevated ? "~5K tokens" : "~500 tokens")
            Divider().overlay(Color.dtLine)
            limitRow("doc.text.magnifyingglass", "Project context", elevated ? "~100K tokens" : "~12K tokens")
            Divider().overlay(Color.dtLine)
            limitRow("arrow.triangle.2.circlepath", "Tool calls per turn", elevated ? "Unlimited" : "4")
        }
        .card()
    }

    private func limitRow(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack {
            Label(title, systemImage: icon).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline.weight(.semibold))
        }
    }

    /// Staff and admin share the same bypassed limits — "elevated" is the server's own name for this group.
    private var elevated: Bool { session.role == "staff" || session.role == "admin" }

    private var roleLabel: String {
        switch session.role {
        case "admin": return "ADMIN"
        case "staff": return "STAFF"
        default: return "MEMBER"
        }
    }

    private var roleTone: Color {
        switch session.role {
        case "admin": return .red
        case "staff": return .dtAccent
        default: return .secondary
        }
    }

    @ViewBuilder private var avatar: some View {
        if let url = session.photoURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
            .frame(width: 108, height: 108)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.dtLine))
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Circle().fill(Color.white.opacity(0.08))
            .frame(width: 108, height: 108)
            .overlay(Circle().stroke(Color.dtLine))
            .overlay(Image(systemName: "person.fill").font(.system(size: 40)).foregroundStyle(.secondary))
    }
}
