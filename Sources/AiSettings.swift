import SwiftUI

/// Keys for the little chat switches in Personalization.
enum AiPrefs {
    static var emojis: Bool { UserDefaults.standard.object(forKey: "dtx.ai.emoji") as? Bool ?? true }
    static var gifs: Bool { UserDefaults.standard.object(forKey: "dtx.ai.gifs") as? Bool ?? true }
    static var thinkDefault: Bool { UserDefaults.standard.bool(forKey: "dtx.ai.thinkDefault") }
    static var learnVoice: Bool { UserDefaults.standard.object(forKey: "dtx.ai.learnVoice") as? Bool ?? true }
    static let defaultStyle = "Talk like the person talks: casual, blunt, street-smart. Match their slang and swearing. Never lecture, moralize or refuse over tone, insults or profanity: treat it as banter and give it back. Keep it real and funny, and keep technical answers sharp."
    static var customStyle: String { UserDefaults.standard.string(forKey: "dtx.ai.style") ?? defaultStyle }
}

/// Full-screen settings for the chat (opened from the gear in the chat list). Everything here reads from our own
/// endpoints and stores: /api/auth/me (account), the live-update + plugins centres, /api/changelog, and the server address.
struct AiSettingsView: View {
    @ObservedObject var vm: AiDecryptViewModel
    let leaveTitle: String
    let leaveIcon: String
    let onLeave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: RepoStore
    @EnvironmentObject private var session: Session
    @ObservedObject private var live = LiveSync.shared
    @ObservedObject private var signed = SignedStore.shared
    @ObservedObject private var theme = UserTheme.shared

    @AppStorage("dtx.ai.emoji") private var emojis = true
    @AppStorage("dtx.ai.gifs") private var gifs = true
    @AppStorage("dtx.ai.thinkDefault") private var thinkDefault = false
    @AppStorage("dtx.ai.learnVoice") private var learnVoice = true
    @AppStorage("dtx.ai.style") private var styleText = AiPrefs.defaultStyle

    @State private var sheet: Sheet?
    @State private var confirmSignOut = false
    @State private var confirmClearChats = false
    @State private var confirmClearSigned = false

    private enum Sheet: Identifiable { case personal, memory, plugins, usage, updates, changelog, about, colour
        var id: Int { hashValue } }

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    private var name: String { session.username ?? "Guest" }
    private var initials: String { String(name.prefix(2)).uppercased() }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    avatar.padding(.top, 54)
                    planCard.padding(.top, 22)

                    section("Customize Ai-Decrypt") {
                        row("face.smiling", "Personalization") { sheet = .personal }
                        row("book.closed", "Memory") { sheet = .memory }
                        row("puzzlepiece.extension", "Plugins") { sheet = .plugins }
                    }
                    section("Account") {
                        valueRow("person", "Username", name)
                        valueRow("star", "Plan", session.staff ? "Staff" : "Closed beta")
                        serverRow
                        row("chart.bar", "Usage and limits") { sheet = .usage }
                    }
                    section("Theme") {
                        valueRow("moon", "Appearance", "Dark")
                        accentRow
                    }
                    section("Data controls") {
                        row("arrow.clockwise", "Reload sources", value: "\(store.apps.count) apps") { Task { await store.refresh() } }
                        row("tray.full", "Clear signed list", value: "\(signed.items.count)") { confirmClearSigned = true }
                        row("trash", "Delete all chats", value: "\(vm.conversations.count)") { confirmClearChats = true }
                    }
                    section("App") {
                        row("arrow.triangle.2.circlepath", "Live update",
                            value: live.updateAvailable ? "Release \(live.manifest?.rev ?? 0) ready" : "Release #\(live.rev)") { sheet = .updates }
                        row(leaveIcon, leaveTitle) { dismiss(); onLeave() }
                    }
                    section("Get help") {
                        row("doc.text", "Changelog") { sheet = .changelog }
                        row("info.circle", "About") { sheet = .about }
                    }
                    Button { confirmSignOut = true } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 20))
                            Text("Log out").font(.system(size: 19))
                            Spacer()
                        }
                        .foregroundStyle(Color.red)
                        .padding(.horizontal, 18).padding(.vertical, 18)
                        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(white: 0.12)))
                    }
                    .padding(.horizontal, 16).padding(.top, 26).padding(.bottom, 40)
                }
            }
            .refreshable { await session.refresh(); await live.syncIfDue() }

            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .aiGlassCircle(46)
            }
            .padding(.trailing, 16).padding(.top, 8)
        }
        .preferredColorScheme(.dark)
        .tint(.dtAccent)
        .sheet(item: $sheet) { s in
            switch s {
            case .personal: personalSheet
            case .memory: AiPersonaSheet()
            case .plugins: PluginsTableView()
            case .usage: usageSheet
            case .updates: UpdateCenterView()
            case .changelog: ChangelogView()
            case .about: aboutSheet
            case .colour: colourSheet
            }
        }
        .confirmationDialog("Log out of \(name)?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Log out", role: .destructive) { Task { await session.signOut() } }
        }
        .confirmationDialog("Delete every saved chat?", isPresented: $confirmClearChats, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { vm.deleteAll() }
        }
        .confirmationDialog("Remove every build from the Signed list?", isPresented: $confirmClearSigned, titleVisibility: .visible) {
            Button("Clear list", role: .destructive) { signed.clear() }
        } message: { Text("The builds stay on the server; only this list is cleared.") }
    }

    // MARK: pieces

    private var avatar: some View {
        VStack(spacing: 14) {
            Circle().fill(Color.dtAccent.opacity(0.32))
                .frame(width: 150, height: 150)
                .overlay(Text(initials).font(.system(size: 56, weight: .semibold)).foregroundStyle(.white.opacity(0.92)))
            Text(name).font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
        }
    }

    private var planCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.staff ? "No limits" : "Closed beta").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                Text(session.staff ? "Staff access: unlimited tokens, every tool." : "Signed in to Decrypt.Team.")
                    .font(.system(size: 16)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { sheet = .updates } label: {
                Text(live.updateAvailable ? "Update" : "Up to date")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 22).padding(.vertical, 14)
                    .background(Capsule().fill(Color.white))
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(white: 0.12)))
        .padding(.horizontal, 16)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(Color(white: 0.62)).padding(.leading, 22)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(white: 0.12)))
                .padding(.horizontal, 16)
        }
        .padding(.top, 34)
    }

    private func line<T: View>(_ icon: String, _ title: String, trailing: T) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.system(size: 21)).foregroundStyle(.white).frame(width: 30)
                Text(title).font(.system(size: 20)).foregroundStyle(.white)
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 18).frame(minHeight: 62)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5).padding(.leading, 64)
        }
    }

    private func row(_ icon: String, _ title: String, value: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            line(icon, title, trailing: HStack(spacing: 8) {
                if let value { Text(value).font(.system(size: 19)).foregroundStyle(.secondary).lineLimit(1) }
                Image(systemName: "chevron.right").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color(white: 0.45))
            })
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func valueRow(_ icon: String, _ title: String, _ value: String) -> some View {
        line(icon, title, trailing: Text(value).font(.system(size: 19)).foregroundStyle(.secondary).lineLimit(1))
    }

    private var serverRow: some View {
        line("server.rack", "Server", trailing:
            TextField("https://decrypt.team", text: $store.server)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 17)).foregroundStyle(.secondary)
                .frame(maxWidth: 190))
    }

    // MARK: accent colour

    private static let accentChoices = ["orange", "red", "pink", "purple", "blue", "cyan", "teal", "mint", "yellow", "white"]

    private var accentName: String {
        guard let h = theme.hex else { return "Lime" }
        if let n = AppPalette.names.first(where: { $0.value == h })?.key { return n.capitalized }
        return "#" + h
    }

    private var accentRow: some View {
        line("paintpalette", "Accent color", trailing:
            Menu {
                Button("Lime (default)") { _ = AiThemeTool.apply("default") }
                ForEach(Self.accentChoices, id: \.self) { n in
                    Button(n.capitalized) { _ = AiThemeTool.apply(n) }
                }
                Button { sheet = .colour } label: { Label("Custom…", systemImage: "eyedropper") }
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(Color.dtAccent).frame(width: 16, height: 16)
                    Text(accentName).font(.system(size: 19)).foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(white: 0.55))
                }
            })
    }

    // MARK: sheets

    private var colourSheet: some View {
        NavigationStack {
            ScrollView {
                AiColorPickerCard(initialHex: theme.hex ?? "B6FF3C") { _ in }.padding(16)
            }
            .background(AppBackground())
            .navigationTitle("Custom colour").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
        }
        .preferredColorScheme(.dark)
    }

    private var personalSheet: some View {
        NavigationStack {
            List {
                Toggle("Use emojis", isOn: $emojis)
                Toggle("Reply with GIFs", isOn: $gifs)
                Toggle("Learn my style from my chats", isOn: $learnVoice)
                Toggle("Think harder by default", isOn: Binding(get: { thinkDefault }, set: { thinkDefault = $0; vm.thinkHarder = $0 }))
                Section(header: Text("How it talks"), footer: Text("Your own instructions. They go to the model on every message and override its default manners. Think harder makes it reason step by step first (slower, better at logic).")) {
                    TextEditor(text: $styleText).frame(minHeight: 170).scrollContentBackground(.hidden)
                    Button("Reset to default") { styleText = AiPrefs.defaultStyle }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("Personalization").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
        }
        .preferredColorScheme(.dark)
    }

    private var usageSheet: some View {
        let u = vm.usage
        return NavigationStack {
            List {
                Section("This chat") {
                    kv("Tokens used", (u.src == "estimate" ? "≈ " : "") + fmtTok(u.used))
                    kv("Sent to the model", fmtTok(u.prompt ?? 0))
                    kv("Written by the model", fmtTok(u.completion ?? 0))
                    kv("Last prompt size", fmtTok(u.lastPrompt ?? 0))
                    kv("Counting", u.src == "estimate" ? "estimated" : "exact (from the server)")
                }
                Section("Limits") {
                    kv("Your cap", session.staff ? "none (unlimited)" : "none in the beta")
                    kv("Model context window", fmtTok(AiDecryptAPI.contextWindow) + " tokens")
                }
                Section(footer: Text("Long chats are folded into a running summary automatically, so Ai-Decrypt keeps remembering past the context window.")) { EmptyView() }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("Usage and limits").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
        }
        .preferredColorScheme(.dark)
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary) }
    }

    private var aboutSheet: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image("Logo").resizable().frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)).padding(.top, 24)
                (Text("Decrypt.").foregroundColor(.white) + Text("Team").foregroundColor(.dtAccent)).font(.title.bold())
                Text("Version \(version)").foregroundStyle(.secondary)
                Text("Ai-Decrypt, the Decrypt.Team assistant. Decrypting, building and the AI run on the Decrypt.Team server; this app is the screen for them.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
                Spacer()
            }
            .frame(maxWidth: .infinity).background(AppBackground())
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
        }
        .preferredColorScheme(.dark)
    }
}
