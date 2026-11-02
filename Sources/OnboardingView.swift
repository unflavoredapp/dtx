import SwiftUI

/// First screen of the app. Three intro pages, then the Telegram sign-in. The app is in a closed beta for Decrypt.Team staff.
struct OnboardingView: View {
    @EnvironmentObject var session: Session
    @Environment(\.openURL) private var openURL
    @AppStorage("dt.onboarded") private var seen = false
    @State private var page = 0

    private let pages: [(icon: String, title: String, text: String)] = [
        ("magnifyingglass", "Find any app", "Search the repos you add and see every version, size and bundle ID in one place."),
        ("lock.open.fill", "Decrypt & inject", "Builds run on the Decrypt.Team server. dtx.dylib goes into every build, and you can add your own libraries."),
        ("wrench.and.screwdriver.fill", "Analysis tools", "Run first-party tools on any IPA: load commands, bundles, strings and more."),
    ]

    private var onLogin: Bool { seen || page >= pages.count }

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

    // MARK: intro

    private var intro: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { finishIntro() }.font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                    VStack(spacing: 18) {
                        Spacer()
                        Image(systemName: p.icon)
                            .font(.system(size: 54, weight: .semibold))
                            .foregroundStyle(Color.dtAccent)
                            .frame(width: 118, height: 118)
                            .background(Color.dtCard)
                            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Color.dtLine))
                        Text(p.title).font(.title.bold())
                        Text(p.text).font(.body).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 6)
                        Spacer()
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            Button {
                if page < pages.count - 1 { withAnimation { page += 1 } } else { finishIntro() }
            } label: {
                Text(page < pages.count - 1 ? "Continue" : "Get started").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .padding(.bottom, 24)
        }
    }

    private func finishIntro() { seen = true; page = pages.count }

    // MARK: sign in

    private var login: some View {
        VStack(spacing: 16) {
            Spacer()
            Image("Logo").resizable().frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.dtLine))
            Text("Decrypt.Team").font(.largeTitle.bold())
            Pill(text: "CLOSED BETA", tone: .dtAccent)
            Text("This app is only open to Decrypt.Team staff right now. Sign in with the Telegram account that's on the staff list.")
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
