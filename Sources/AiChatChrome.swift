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

/// The slide-in chat list: quick actions, pinned + recent chats, a big "Chat" button and a settings circle.
struct AiSidebar: View {
    @ObservedObject var vm: AiDecryptViewModel
    let onClose: () -> Void
    let onColorWheel: () -> Void
    let onGif: () -> Void
    let leaveTitle: String
    let leaveIcon: String
    let onLeave: () -> Void

    @State private var query = ""
    @State private var searching = false
    @State private var confirmClear = false
    @FocusState private var searchFocused: Bool

    private var filtered: [SavedConversation] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return vm.conversations }
        return vm.conversations.filter { $0.title.lowercased().contains(q) }
    }
    private var pinned: [SavedConversation] { filtered.filter { $0.pinned == true } }
    private var recents: [SavedConversation] { filtered.filter { $0.pinned != true } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if searching {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search chats", text: $query)
                            .focused($searchFocused)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .aiGlass(Capsule())
                } else {
                    Text("Ai-Decrypt").font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
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
                    action("square.and.pencil", "New chat") { vm.newChat(); onClose() }
                    action("paintpalette", "Colour wheel") { onColorWheel() }
                    action("face.smiling", "GIFs") { onGif() }

                    if !pinned.isEmpty {
                        header("Pinned")
                        ForEach(pinned) { row($0) }
                    }
                    header("Recents")
                    if recents.isEmpty && pinned.isEmpty {
                        Text(query.isEmpty ? "No saved chats yet." : "No chats match.")
                            .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 8)
                    }
                    ForEach(recents) { row($0) }
                    Color.clear.frame(height: 90)
                }
                .padding(.horizontal, 8)
            }
            .scrollDismissesKeyboard(.immediately)
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
                Menu {
                    Button { onLeave() } label: { Label(leaveTitle, systemImage: leaveIcon) }
                    Button(role: .destructive) { confirmClear = true } label: { Label("Delete all chats", systemImage: "trash") }
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                        .aiGlassCircle(52)
                }
            }
            .padding(.horizontal, 18).padding(.bottom, 14).padding(.top, 20)
            .background(LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
        }
        .confirmationDialog("Delete every saved chat?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { vm.deleteAll(); onClose() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.top, 22).padding(.bottom, 6)
    }

    private func action(_ icon: String, _ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
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

    private func row(_ c: SavedConversation) -> some View {
        Button { vm.open(c.id); onClose() } label: {
            HStack(spacing: 8) {
                Text(c.title).font(.system(size: 18)).lineLimit(1).foregroundStyle(.white)
                Spacer(minLength: 0)
                if c.pinned == true { Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12).padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(c.id == vm.currentID ? Color.white.opacity(0.09) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { vm.togglePin(c.id) } label: { Label(c.pinned == true ? "Unpin" : "Pin", systemImage: c.pinned == true ? "pin.slash" : "pin") }
            Button(role: .destructive) { vm.delete(c.id) } label: { Label("Delete", systemImage: "trash") }
        }
    }
}
