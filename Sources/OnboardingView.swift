import SwiftUI

/// First screen of the app: one intro page (what it is, why it is locked), then the Telegram sign-in. Closed beta for Decrypt.Team staff.
struct OnboardingView: View {
    @EnvironmentObject var session: Session
    @Environment(\.openURL) private var openURL
    @AppStorage("dt.onboarded") private var seen = false
    private var onLogin: Bool { seen }

    var body: some View {
        ZStack {
            Color.dtBG.ignoresSafeArea()
            RadialGradient(colors: [Color.dtAccent.opacity(0.22), .clear], center: .top, startRadius: 10, endRadius: 420)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                if onLogin { login.transition(.opacity) } else { intro.transition(.opacity) }
            }
            .padding(.horizontal, 24)
        }
        .animation(.easeInOut(duration: 0.25), value: onLogin)
    }

    // MARK: intro (one page: what this is, and why it's locked)

    private var intro: some View {
        VStack(spacing: 16) {
            Spacer()
            Image("Logo").resizable().frame(width: 112, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.dtLine))
                .shadow(color: Color.dtAccent.opacity(0.25), radius: 24)
            Text("Decrypt.Team").font(.largeTitle.bold())
            Text("iOS app discovery and decryption tools").font(.subheadline).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 14) {
                row("square.stack.3d.up.fill", "What this is",
                    "The Decrypt.Team app. Browse your repos, decrypt apps and inject libraries on our server, and run analysis tools on any IPA.")
                Divider().overlay(Color.dtLine)
                row("lock.fill", "Why it's locked",
                    "The app is in a closed beta for Decrypt.Team staff. We're still testing it, and the server does the heavy work, so access is limited to the team until it's ready.")
            }
            .card()
            .padding(.top, 8)
            Spacer()
            Button { seen = true } label: {
                Text("Continue").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .padding(.bottom, 24)
        }
    }

    private func row(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.dtAccent).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: sign in

    private var login: some View {
        VStack(spacing: 16) {
            Spacer()
            Image("Logo").resizable().frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.dtLine))
            Text("Decrypt.Team").font(.largeTitle.bold())
            Pill(text: "CLOSED BETA", tone: .dtAccent)
            Text("Sign in with the Telegram account that's on the Decrypt.Team staff list.")
                .font(.body).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 4)
            status
            Spacer()
            Button(action: start) {
                HStack(spacing: 10) {
                    if busy { ProgressView().tint(.white) } else { Image(systemName: "paperplane.fill") }
                    Text(busy ? "Waiting for Telegram…" : "Authorize with Telegram").font(.headline)
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
        .padding(.bottom, 24)
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
