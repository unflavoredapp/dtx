import SwiftUI

/// The Tools hub: every tool in one place, grouped, searchable and filterable.
struct ToolsHubView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var query = ""
    @State private var chip: Chip = .all
    @State private var sheet: HubSheet?

    enum Chip: String, CaseIterable, Identifiable {
        case all = "All", decrypt = "Decrypt", build = "Build", analyze = "Analyze", manage = "Manage"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .all: return "square.grid.2x2.fill"
            case .decrypt: return "lock.open"
            case .build: return "hammer"
            case .analyze: return "magnifyingglass"
            case .manage: return "slider.horizontal.3"
            }
        }
    }

    enum HubSheet: String, Identifiable {
        case signer, batch, install, certificate, theme, decrypt, inspector, updates, repos
        var id: String { rawValue }
    }

    enum Action { case sheet(HubSheet), web(String), chat }

    struct Tool: Identifiable {
        var id: String { name }
        let name: String
        let sub: String
        let icon: String
        let chip: Chip
        var exclusive = false
        let action: Action
    }

    struct Group: Identifiable {
        var id: String { title }
        let title: String
        let caption: String
        let columns: Int
        let tools: [Tool]
    }

    private static let site = "https://decrypt.team/tools"

    private var groups: [Group] { Self.catalog }

    /// Every tool, grouped. Also listed under Tools in an app's sign options.
    static var catalog: [Group] {
        let site = Self.site
        return [
            Group(title: "Featured", caption: "Most used tools and services.", columns: 3, tools: [
                Tool(name: "Decrypt Dylib", sub: "Reconstruct a dylib", icon: "chevron.left.forwardslash.chevron.right", chip: .decrypt, exclusive: true, action: .web(site)),
                Tool(name: "IPA Builder", sub: "Build from source", icon: "hammer.fill", chip: .build, exclusive: true, action: .web(site)),
                Tool(name: "Certificates", sub: "Import and pick", icon: "checkmark.seal.fill", chip: .manage, action: .sheet(.certificate)),
            ]),
            Group(title: "Build & Modify", caption: "Inject, patch and rebuild apps.", columns: 2, tools: [
                Tool(name: "Injector", sub: "Add dylibs and frameworks", icon: "puzzlepiece.extension.fill", chip: .build, action: .sheet(.decrypt)),
                Tool(name: "Batch", sub: "Many apps in parallel", icon: "square.stack.3d.up.fill", chip: .build, action: .sheet(.batch)),
            ]),
            Group(title: "Analyze & Inspect", caption: "Understand what is inside an app.", columns: 2, tools: [
                Tool(name: "App Info", sub: "IDs, permissions", icon: "info.circle.fill", chip: .analyze, action: .sheet(.inspector)),
                Tool(name: "Package", sub: "Files and frameworks", icon: "shippingbox.fill", chip: .analyze, action: .sheet(.inspector)),
                Tool(name: "Info.plist", sub: "Full file", icon: "doc.plaintext.fill", chip: .analyze, action: .sheet(.inspector)),
                Tool(name: "Link Check", sub: "Is the IPA alive", icon: "link.circle.fill", chip: .analyze, action: .sheet(.inspector)),
                Tool(name: "Binary", sub: "Archs, encryption", icon: "cpu.fill", chip: .analyze, action: .sheet(.inspector)),
                Tool(name: "Bundles", sub: "Frameworks, extensions", icon: "archivebox.fill", chip: .analyze, action: .sheet(.inspector)),
                Tool(name: "Privacy", sub: "Manifest and APIs", icon: "hand.raised.fill", chip: .analyze, action: .sheet(.inspector)),
                Tool(name: "Load Commands", sub: "Mach-O", icon: "terminal.fill", chip: .analyze, action: .sheet(.inspector)),
                Tool(name: "Strings", sub: "Readable text", icon: "textformat", chip: .analyze, action: .sheet(.inspector)),
            ]),
            Group(title: "Repo & Libraries", caption: "Sources, updates and saved libraries.", columns: 3, tools: [
                Tool(name: "Repo Studio", sub: "Your sources", icon: "server.rack", chip: .build, action: .sheet(.repos)),
                Tool(name: "Dylib Studio", sub: "Analyse and build", icon: "cylinder.split.1x2.fill", chip: .analyze, action: .web(site)),
                Tool(name: "Flow Graph", sub: "Binary functions", icon: "point.3.connected.trianglepath.dotted", chip: .analyze, action: .web(site)),
            ]),
            Group(title: "Services", caption: "Automation and AI.", columns: 2, tools: [
                Tool(name: "Ai-Decrypt", sub: "Chat runs the tools", icon: "sparkles", chip: .decrypt, action: .chat),
                Tool(name: "App Requests", sub: "Ask for any app", icon: "plus.app.fill", chip: .decrypt, action: .web(site)),
                Tool(name: "Updates", sub: "Newer versions of your apps", icon: "arrow.triangle.2.circlepath", chip: .decrypt, action: .sheet(.updates)),
                Tool(name: "AppAssassin", sub: "Telegram bot", icon: "paperplane.fill", chip: .decrypt, action: .web(site)),
            ]),
            Group(title: "Manage", caption: "Install, sign and customize.", columns: 2, tools: [
                Tool(name: "Signer", sub: "Sign builds", icon: "pencil.tip.crop.circle", chip: .manage, action: .sheet(.signer)),
                Tool(name: "Install", sub: "Native, local VPN", icon: "iphone.and.arrow.forward", chip: .manage, action: .sheet(.install)),
                Tool(name: "Certificate", sub: "p12 and profile", icon: "checkmark.seal", chip: .manage, action: .sheet(.certificate)),
                Tool(name: "Theme", sub: "Accent, backgrounds", icon: "paintpalette.fill", chip: .manage, action: .sheet(.theme)),
                Tool(name: "DTX wallet", sub: "Balance, Premium", icon: "creditcard.fill", chip: .manage, action: .web(site)),
                Tool(name: "Scratch card", sub: "Daily prizes", icon: "ticket.fill", chip: .manage, action: .web(site)),
            ]),
        ]
    }

    private func visible(_ g: Group) -> [Tool] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return g.tools.filter { t in
            (chip == .all || t.chip == chip) && (q.isEmpty || t.name.lowercased().contains(q) || t.sub.lowercased().contains(q))
        }
    }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(spacing: 14) {
                    topBar
                    VStack(spacing: 2) {
                        Text("Tools").font(.system(size: 28, weight: .heavy))
                        Text("All tools in one place").font(.subheadline).foregroundStyle(.secondary)
                    }
                    searchField
                    chipRow
                    ForEach(groups) { g in
                        let tools = visible(g)
                        if !tools.isEmpty { section(g, tools) }
                    }
                    if groups.allSatisfy({ visible($0).isEmpty }) {
                        Text("No tools match.").foregroundStyle(.secondary).padding(.top, 30)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 30)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $sheet) { s in Self.sheetView(s) }
    }

    // MARK: pieces

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                    .frame(width: 46, height: 46).background(Circle().fill(Color(white: 0.11))).overlay(Circle().stroke(Color.white.opacity(0.09), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            Spacer()
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.dtAccent).frame(width: 26, height: 30)
                    .overlay(Image(systemName: "lock.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.dtOnAccent))
                (Text("Decrypt").foregroundColor(.white) + Text(".Team").foregroundColor(Color.dtAccent))
                    .font(.system(size: 22, weight: .bold))
            }
            Spacer()
            Color.clear.frame(width: 46, height: 46)
        }
        .padding(.top, 8)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search tools…", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).frame(height: 46)
        .background(Capsule().fill(Color(white: 0.07)))
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Chip.allCases) { c in
                    let on = chip == c
                    Button { withAnimation(.easeInOut(duration: 0.15)) { chip = c } } label: {
                        Label(c.rawValue, systemImage: c.icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(on ? Color.dtOnAccent : Color.white)
                            .padding(.horizontal, 14).frame(height: 38)
                            .background(Capsule().fill(on ? Color.dtAccent : Color(white: 0.08)))
                            .overlay(Capsule().stroke(Color.white.opacity(on ? 0 : 0.1), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func section(_ g: Group, _ tools: [Tool]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color.dtAccent).frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(g.title).font(.system(size: 17, weight: .bold))
                    Text(g.caption).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: g.columns), spacing: 8) {
                ForEach(tools) { t in
                    Button { run(t) } label: { g.columns == 2 ? AnyView(wideCard(t)) : AnyView(tallCard(t)) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(white: 0.055)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    private func iconTile(_ name: String, _ size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(colors: [Color.dtAccent.opacity(0.22), Color.dtAccent.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.dtAccent.opacity(0.22), lineWidth: 1))
            .frame(width: size, height: size)
            .overlay(Image(systemName: name).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(Color.dtAccent))
    }

    private func tallCard(_ t: Tool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                iconTile(t.icon, 40)
                Spacer(minLength: 0)
            }
            Text(t.name).font(.system(size: 14, weight: .bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
            Text(t.sub).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
            if t.exclusive {
                Text("EXCLUSIVE").font(.system(size: 9, weight: .heavy)).foregroundStyle(Color.dtOnAccent)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.dtAccent))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(t.exclusive ? Color.dtAccent.opacity(0.10) : Color(white: 0.085)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(t.exclusive ? Color.dtAccent.opacity(0.55) : Color.white.opacity(0.09), lineWidth: 1))
        .shadow(color: t.exclusive ? Color.dtAccent.opacity(0.18) : .clear, radius: 10)
    }

    private func wideCard(_ t: Tool) -> some View {
        HStack(spacing: 10) {
            iconTile(t.icon, 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.name).font(.system(size: 14, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                Text(t.sub).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 64)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.085)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 1))
    }

    // MARK: actions

    private func run(_ t: Tool) {
        ActivityStore.shared.log("Tools", "opened " + t.name)
        switch t.action {
        case .sheet(let s): sheet = s
        case .web(let u): if let url = URL(string: u) { openURL(url) }
        case .chat: dismiss()
        }
    }

    @ViewBuilder static func sheetView(_ s: HubSheet) -> some View {
        switch s {
        case .signer: SignerView()
        case .batch: BatchView()
        case .install: DeviceSetupView()
        case .certificate: CertificateView()
        case .theme: ThemeScreen()
        case .decrypt: QuickBuildView()
        case .inspector: IPAInspectorView()
        case .updates: UpdatesView()
        case .repos: ReposView()
        }
    }
}
