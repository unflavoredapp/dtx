import SwiftUI

/// The first screen: who you are, your certificate, DTX balance and wallet, today's usage, popular apps, the daily scratch card.
struct HubView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var store: RepoStore
    @ObservedObject private var wallet = DTXWallet.shared

    @State private var scratching = false
    @State private var scratchMsg: String?
    @State private var revealed = false
    @State private var copied = false

    private let usageOrder: [(String, String, String)] = [
        ("decrypt", "Decrypts", "lock.open"), ("inject", "Injects", "syringe"),
        ("ai_message", "AI messages", "bubble.left.and.bubble.right"), ("ai_vision", "AI image chats", "photo"),
        ("dylib_studio", "Dylib Studio", "hammer"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                profileCard
                if session.signedIn {
                    balanceCard
                    scratchCard
                    usageCard
                } else {
                    signInCard
                }
                topAppsCard
                if let e = wallet.error { Text(e).font(.footnote).foregroundStyle(.secondary) }
                Color.clear.frame(height: 80)
            }
            .padding(.horizontal, 16).padding(.top, 70)
        }
        .background(AppBackground())
        .refreshable { await wallet.refresh() }
        .task { await wallet.refresh(); await wallet.loadStats(store.apps.map(\.bid)) }
    }

    // MARK: cards

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var profileCard: some View {
        card {
            HStack(spacing: 14) {
                Group {
                    if let u = session.photoURL {
                        AsyncImage(url: u) { p in if let i = p.image { i.resizable().scaledToFill() } else { Color.dtAccent.opacity(0.3) } }
                    } else {
                        Color.dtAccent.opacity(0.3).overlay(Image(systemName: "person.fill").foregroundStyle(.white.opacity(0.8)))
                    }
                }
                .frame(width: 56, height: 56).clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.username ?? "Guest").font(.system(size: 20, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    Text(session.signedIn ? session.role.capitalized : "Not signed in").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                certBadge
            }
        }
    }

    @ViewBuilder private var certBadge: some View {
        let active = wallet.hub?.certificate?.active ?? false
        VStack(spacing: 3) {
            Image(systemName: active ? "checkmark.seal.fill" : "checkmark.seal")
                .font(.system(size: 22)).foregroundStyle(active ? Color.dtAccent : Color.secondary)
            Text(active ? "Certificate" : "No cert").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(active ? Color.dtAccent : Color.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private var balanceCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("DTX BALANCE").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    DTXCoin(size: 34).alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 4 }
                    Text("\(wallet.balance)").font(.system(size: 38, weight: .bold, design: .rounded)).foregroundStyle(Color.dtAccent)
                    Text("DTX").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                }
                if let a = wallet.hub?.user?.address, !a.isEmpty {
                    Button {
                        UIPasteboard.general.string = a; copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            Text(a).lineLimit(1).truncationMode(.middle).font(.system(size: 12, design: .monospaced))
                        }
                        .foregroundStyle(.white.opacity(0.85)).padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                    }.buttonStyle(.plain)
                }
                if let h = wallet.hub?.history, !h.isEmpty {
                    Divider().overlay(Color.white.opacity(0.1))
                    ForEach(h.prefix(5)) { e in
                        HStack {
                            Text(e.label).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                            Spacer()
                            Text((e.delta > 0 ? "+" : "") + "\(e.delta)").font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(e.delta > 0 ? Color.dtAccent : Color.secondary)
                        }
                    }
                }
            }
        }
    }

    private var scratchCard: some View {
        let avail = wallet.hub?.scratch?.available ?? false
        let prize = scratchMsg ?? wallet.hub?.scratch?.prize
        return card {
            HStack(spacing: 14) {
                Image(systemName: avail ? "gift.fill" : "gift").font(.system(size: 26)).foregroundStyle(avail ? Color.dtAccent : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Daily scratch card").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    Text(avail ? "Free DTX every day. Tap to scratch." : (prize.map { "Today: \($0). Back tomorrow." } ?? "Back tomorrow."))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if avail {
                    Button {
                        guard !scratching else { return }
                        scratching = true
                        Task {
                            do {
                                let r = try await wallet.scratch()
                                withAnimation { scratchMsg = r.prize }
                            } catch { scratchMsg = error.localizedDescription }
                            scratching = false
                        }
                    } label: {
                        Text(scratching ? "…" : "Scratch").font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                            .padding(.horizontal, 16).padding(.vertical, 9).background(Capsule().fill(Color.dtAccent))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var usageCard: some View {
        let used = wallet.hub?.usageToday ?? [:]
        let prices = wallet.hub?.prices ?? [:]
        return card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("TODAY").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(wallet.hub?.spentToday ?? 0) DTX spent").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
                ForEach(usageOrder, id: \.0) { key, title, icon in
                    HStack(spacing: 12) {
                        Image(systemName: icon).frame(width: 22).foregroundStyle(Color.dtAccent)
                        Text(title).font(.system(size: 14)).foregroundStyle(.white)
                        Spacer()
                        Text("\(used[key]?.count ?? 0) used").font(.system(size: 13)).foregroundStyle(.secondary)
                        if let p = prices[key] { Text("\(p) DTX each").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary.opacity(0.8)) }
                    }
                }
            }
        }
    }

    private var signInCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sign in to use DTX").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                Text("Your Telegram login gives you a DTX wallet. DTX pays for decrypts, injects and AI messages, and a daily scratch card gives you free DTX.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Button { session.loginWithTelegram { url in UIApplication.shared.open(url, options: [:], completionHandler: nil) } } label: {
                    Text("Sign in with Telegram").font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 16).padding(.vertical, 9).background(Capsule().fill(Color.dtAccent))
                }.buttonStyle(.plain)
            }
        }
    }

    private var topAppsCard: some View {
        let top = (wallet.hub?.topApps ?? []).prefix(6)
        let byBid = Dictionary(store.apps.map { ($0.bid, $0) }, uniquingKeysWith: { a, _ in a })
        return card {
            VStack(alignment: .leading, spacing: 10) {
                Text("POPULAR APPS").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                if top.isEmpty {
                    Text("Counts appear here as people open and download apps.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                ForEach(Array(top)) { t in
                    let app = byBid[t.id]
                    Button { if let app { store.pickedApp = app } } label: {
                        HStack(spacing: 12) {
                            AppIconView(url: app?.icon, name: app?.name ?? t.id, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app?.name ?? t.id).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                Text("\(compactCount(t.views)) views · \(compactCount(t.downloads)) downloads")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}
