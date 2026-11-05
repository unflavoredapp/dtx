import SwiftUI

/// First screen of the app: a floating popup over a dimmed background — Telegram sign-in for full staff
/// access, or Continue as guest. The server still enforces its own guest quotas and staff-only checks
/// regardless of which path someone takes here.
struct OnboardingView: View {
    @EnvironmentObject var session: Session
    @Environment(\.openURL) private var openURL
    @State private var appear = false

    var body: some View {
        ZStack {
            AppBackground()
            Color.black.opacity(appear ? 0.4 : 0).ignoresSafeArea()
            card
                .scaleEffect(appear ? 1 : 0.92)
                .opacity(appear ? 1 : 0)
        }
        .onAppear { withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { appear = true } }
    }

    private var card: some View {
        VStack(spacing: 18) {
            Image("Logo").resizable().frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.dtLine))
            VStack(spacing: 6) {
                Text("Uncrypt").font(.title2.bold())
                Text("Uncrypt is the chat built into the app — it finds and decrypts apps, inspects crashes, and writes dylibs with you. Staff get full access — sign in with Telegram, or look around as a guest.")
                    .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            status
            VStack(spacing: 12) {
                Button(action: start) {
                    HStack(spacing: 10) {
                        if busy { ProgressView().tint(.white) } else { Image(systemName: "paperplane.fill") }
                        Text(busy ? "Waiting for Telegram…" : "Sign in with Telegram").font(.headline)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(Color(red: 0.16, green: 0.62, blue: 0.86))
                .disabled(busy)

                if busy {
                    Button("Cancel") { session.cancelLogin() }.font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Button("Continue as guest") { session.continueAsGuest() }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 22)
        .frame(maxWidth: 340)
        .padding(.horizontal, 28)
    }

    private var busy: Bool {
        switch session.phase { case .opening, .waiting: return true; default: return false }
    }

    @ViewBuilder private var status: some View {
        switch session.phase {
        case .waiting(let m): Label(m, systemImage: "clock").font(.subheadline).foregroundStyle(Color.dtAccent)
        case .denied(let m):
            Label(m, systemImage: "lock.fill").font(.subheadline).foregroundStyle(Color.red)
                .multilineTextAlignment(.center)
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

/// Pops up once, right after a Telegram login succeeds (`session.justSignedIn`) — a floating card over whatever
/// screen is already loading behind it, not a full screen of its own. Tap Continue (or the scrim) to dismiss.
struct WelcomePopup: View {
    @EnvironmentObject var session: Session
    @State private var appear = false

    var body: some View {
        ZStack {
            Color.black.opacity(appear ? 0.55 : 0)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }
            card
                .scaleEffect(appear ? 1 : 0.92)
                .opacity(appear ? 1 : 0)
        }
        .onAppear { withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { appear = true } }
    }

    private var card: some View {
        VStack(spacing: 20) {
            WelcomeIdentityRow(username: session.username ?? "", role: session.role, photoURL: session.photoURL)
            WelcomeLimitsRow(role: session.role)
            Button(action: dismiss) {
                Text("Continue").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 13)
            }
            .buttonStyle(AccentButtonStyle())
        }
        .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 20)
        .frame(maxWidth: 340)
        .padding(.horizontal, 28)
    }

    private func dismiss() {
        withAnimation(.easeInOut(duration: 0.2)) { appear = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { session.justSignedIn = false }
    }
}

/// Avatar on the left, username + role pill stacked on the right.
private struct WelcomeIdentityRow: View {
    let username: String
    let role: String
    let photoURL: URL?

    var body: some View {
        HStack(spacing: 14) {
            avatar
            VStack(alignment: .leading, spacing: 6) {
                Text(username).font(.title3.bold()).lineLimit(1)
                Pill(text: roleLabel, tone: roleTone)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var avatar: some View {
        if let photoURL {
            AsyncImage(url: photoURL) { phase in
                if let image = phase.image { image.resizable().scaledToFill() } else { placeholder }
            }
            .frame(width: 64, height: 64)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.dtLine))
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Circle().fill(Color.white.opacity(0.08))
            .frame(width: 64, height: 64)
            .overlay(Circle().stroke(Color.dtLine))
            .overlay(Image(systemName: "person.fill").font(.title3).foregroundStyle(.secondary))
    }

    private var roleLabel: String {
        switch role { case "admin": return "ADMIN"; case "staff": return "STAFF"; default: return "MEMBER" }
    }
    private var roleTone: Color {
        switch role { case "admin": return .red; case "staff": return .dtAccent; default: return .secondary }
    }
}

/// Three floating columns (icon over value over label) for the role's real entitlements — no card background
/// of their own, just thin dividers, since they sit inside WelcomePopup's own card. The numbers are the same
/// char caps and tool-call round cap the app and server already enforce (AiDecryptChatView's maxLoops,
/// aiedit.js's OPTIMIZE_CTX_CHARS / elevated message cap), shown here in approximate tokens (chars ÷ 4).
private struct WelcomeLimitsRow: View {
    let role: String

    private var elevated: Bool { role == "staff" || role == "admin" }

    private var columns: [(icon: String, value: String, label: String)] {
        [
            ("text.bubble.fill", elevated ? "~5K" : "~500", "Per message"),
            ("doc.text.magnifyingglass", elevated ? "~100K" : "~12K", "Project context"),
            ("arrow.triangle.2.circlepath", elevated ? "∞" : "4", "Tool calls / turn"),
        ]
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, c in
                if index > 0 { Divider().overlay(Color.dtLine).frame(maxHeight: 44) }
                VStack(spacing: 6) {
                    Image(systemName: c.icon).font(.system(size: 17)).foregroundStyle(Color.dtAccent)
                    Text(c.value).font(.subheadline.weight(.bold))
                    Text(c.label).font(.system(size: 10.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
