import SwiftUI
import UIKit

// MARK: - Floating glass styling (ChatGPT-style chrome)

extension View {
    /// A translucent, blurred shape with a hairline highlight — the floating-button look.
    func aiGlass<S: InsettableShape>(_ shape: S) -> some View {
        // a flat translucent fill — no live blur or big shadow, which is what made scrolling stutter while streaming
        self
            .background(shape.fill(Color(white: 0.115, opacity: 0.95)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5))
    }
    func aiGlassCircle(_ size: CGFloat = 44) -> some View {
        self.frame(width: size, height: size).aiGlass(Circle())
    }
}

// MARK: - Chat transcript export

extension AiDecryptViewModel {
    var currentTitle: String {
        conversations.first(where: { $0.id == currentID })?.title ?? "New chat"
    }
}

// MARK: - Sidebar drawer

/// The slide-in drawer: quick actions, your activity footprint (rendered as chat markdown), a big "Chat" button and a settings circle.
struct AiSidebar: View {
    @ObservedObject var vm: AiDecryptViewModel
    let onClose: () -> Void

    @EnvironmentObject private var session: Session
    @EnvironmentObject private var store: RepoStore
    @State private var query = ""
    @State private var searching = false
    @State private var showSettings = false
    @State private var showEdits = false
    @State private var showTools = false
    @State private var showCertificate = false
    @State private var showDeviceSetup = false
    @State private var showTheme = false
    @State private var showBrowse = false
    @State private var showLibrary = false
    @State private var showSigned = false
    @State private var showSigner = false
    @State private var showDecrypt = false
    @ObservedObject private var activity = ActivityStore.shared
    @ObservedObject private var live = LiveSync.shared
    @State private var openScreen: LiveScreen?
    @FocusState private var searchFocused: Bool


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if searching {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search activity", text: $query)
                            .focused($searchFocused)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .aiGlass(Capsule())
                } else {
                    Text("Uncrypt").font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                    Spacer()
                }
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { searching.toggle() }
                    if searching { searchFocused = true } else { query = ""; searchFocused = false }
                } label: {
                    Image(systemName: searching ? "xmark" : "magnifyingglass")
                        .font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                        .aiGlassCircle(46)
                }
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    profileHeader
                    action("circle.grid.3x3.fill", "Browse", detail: "Opened your sources · \(store.repos.count) repo\(store.repos.count == 1 ? "" : "s")") { onClose(); showBrowse = true }
                    action("square.grid.2x2.fill", "Library", detail: "Opened the app library · \(store.apps.count) app\(store.apps.count == 1 ? "" : "s") indexed") { onClose(); showLibrary = true }
                    action(UIImage(systemName: "signature") != nil ? "signature" : "pencil.and.scribble", "Signed", detail: "Opened signed builds · \(SignedStore.shared.items.count) build\(SignedStore.shared.items.count == 1 ? "" : "s")") { onClose(); showSigned = true }
                    action("pencil.tip.crop.circle", "Signer", detail: "Checked signing readiness") { onClose(); showSigner = true }
                    action("lock.open", "Decrypt", detail: "Opened Decrypt & Inject") { onClose(); showDecrypt = true }
                    action("checkmark.seal", "Certificate", detail: "Opened certificates") { onClose(); showCertificate = true }
                    action("paintpalette", "Theme", detail: "Opened theme") { onClose(); showTheme = true }
                    action("iphone.and.arrow.forward", "Install", detail: "Opened native install setup") { onClose(); showDeviceSetup = true }
                    action("wrench.and.screwdriver", "Tools", detail: "Opened the tools hub") { onClose(); showTools = true }
                    if vm.latestReconProject != nil { action("plus.forwardslash.minus", "Code edits") { showEdits = true } }
                    ForEach((live.config.screens ?? []).filter { ($0.show ?? ["sidebar"]).contains("sidebar") }) { s in
                        action(s.icon ?? "square.grid.2x2", s.title) { openScreen = s }
                    }

                    HStack {
                        header("Activity")
                        Spacer()
                        if !activity.entries.isEmpty {
                            Button("Clear") { activity.clear() }
                                .font(.system(size: 15)).foregroundStyle(.secondary).padding(.trailing, 12).padding(.top, 14)
                        }
                    }
                    MarkdownView(activity.markdown(matching: query))
                        .padding(.horizontal, 12).padding(.bottom, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 90)
                }
                .padding(.horizontal, 8)
            }
            .scrollDismissesKeyboard(.immediately)
            .sheet(item: $openScreen) { LiveScreenSheet(screen: $0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            HStack {
                Button { vm.newChat(); onClose() } label: {
                    Label("Chat", systemImage: "square.and.pencil")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.dtOnAccent)
                        .padding(.horizontal, 26).padding(.vertical, 14)
                        .background(Capsule().fill(Color.dtAccent))
                        .shadow(color: Color.dtAccent.opacity(0.35), radius: 12, y: 4)
                }
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                        .aiGlassCircle(52)
                }
            }
            .padding(.horizontal, 18).padding(.bottom, 14).padding(.top, 20)
            .background(LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
        }
        .sheet(isPresented: $showEdits) {
            if let proj = vm.latestReconProject { AiEditHistorySheet(jobID: proj.jobID, name: proj.name) }
        }
        .sheet(isPresented: $showTools) { ToolsHubView() }
        .sheet(isPresented: $showCertificate) { CertificateView() }
        .sheet(isPresented: $showDeviceSetup) { DeviceSetupView() }
        .sheet(isPresented: $showTheme) { ThemeScreen() }
        .sheet(isPresented: $showBrowse) { ReposView() }
        .sheet(isPresented: $showLibrary) { SearchView() }
        .sheet(isPresented: $showSigned) { SignedView() }
        .sheet(isPresented: $showSigner) { SignerView() }
        .sheet(isPresented: $showDecrypt) { QuickBuildView() }
        .fullScreenCover(isPresented: $showSettings) {
            AiSettingsView(vm: vm)
        }
    }

    /// Telegram photo + username at the top of the list; "Guest" when nobody is signed in.
    private var profileHeader: some View {
        HStack(spacing: 14) {
            profileAvatar
            VStack(alignment: .leading, spacing: 2) {
                Text(session.username ?? "Guest")
                    .font(.system(size: 19, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if session.signedIn {
                    Text(session.role.capitalized).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 10)
    }

    @ViewBuilder private var profileAvatar: some View {
        let fallback = Circle().fill(Color.dtAccent.opacity(0.32))
            .overlay(
                Group {
                    if let u = session.username, let c = u.first {
                        Text(String(c).uppercased()).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                    } else {
                        Image(systemName: "person.fill").font(.system(size: 20)).foregroundStyle(.white.opacity(0.8))
                    }
                }
            )
        if session.signedIn, let url = session.photoURL {
            AsyncImage(url: url) { phase in
                if let img = phase.image { img.resizable().scaledToFill() } else { fallback }
            }
            .frame(width: 46, height: 46).clipShape(Circle())
        } else {
            fallback.frame(width: 46, height: 46)
        }
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.top, 22).padding(.bottom, 6)
    }

    private func action(_ icon: String, _ title: String, detail: String? = nil, _ run: @escaping () -> Void) -> some View {
        Button { ActivityStore.shared.log(title, detail); run() } label: {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.system(size: 20, weight: .regular)).frame(width: 28)
                Text(title).font(.system(size: 19))
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
