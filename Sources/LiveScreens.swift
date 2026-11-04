import SwiftUI
import UIKit

// MARK: - Server-driven screens
//
// A Live Update release can carry whole screens as DATA: a small tree of text / buttons / lists / cards. The app draws
// them with its own native views, so nothing downloaded ever runs as code. A screen can sit in the sidebar and/or be the
// home block on a new chat. Every value is checked here again before it is drawn: types, sizes, depth, symbols, links.

struct LiveAction: Codable {
    var type: String            // open_url | open_screen | ask_ai | copy | sync | close
    var url: String?
    var screen: String?
    var text: String?
}
struct LiveItem: Codable { var title: String; var subtitle: String?; var icon: String?; var action: LiveAction? }
struct LiveKV: Codable { var k: String; var v: String }

struct LiveNode: Codable {
    var t: String
    var text: String?
    var style: String?
    var color: String?
    var align: String?
    var symbol: String?
    var title: String?
    var subtitle: String?
    var icon: String?
    var action: LiveAction?
    var children: [LiveNode]?
    var items: [LiveItem]?
    var rows: [LiveKV]?
    var axis: String?
    var size: Double?
    var key: String?
    var on: Bool?
}

struct LiveScreen: Codable, Identifiable {
    var id: String
    var title: String
    var icon: String?
    var show: [String]?         // "sidebar" and/or "home"
    var body: [LiveNode]
}

enum LiveUI {
    static let types: Set<String> = ["text", "image", "button", "stack", "card", "divider", "spacer", "list", "kv", "badge", "toggle"]
    static let styles: Set<String> = ["title", "headline", "body", "caption", "mono", "primary", "plain", "glass"]
    static let colors: Set<String> = ["accent", "secondary", "white", "red", "green", "orange", "yellow", "blue"]
    static let aligns: Set<String> = ["left", "center", "right"]
    static let actions: Set<String> = ["open_url", "open_screen", "ask_ai", "copy", "sync", "close"]

    static func ident(_ s: String, _ n: Int = 40) -> Bool {
        !s.isEmpty && s.count <= n && s.range(of: "^[A-Za-z0-9_.\\-]+$", options: .regularExpression) != nil
    }
    static func symbol(_ s: String?) -> String? {
        guard let s, !s.isEmpty, s.count <= 60, s.range(of: "^[A-Za-z0-9._]+$", options: .regularExpression) != nil else { return nil }
        return s
    }
    static func cut(_ s: String?, _ n: Int) -> String? { s.map { String($0.prefix(n)) } }

    final class Budget { var nodes = 0 }

    static func action(_ a: LiveAction?) -> LiveAction? {
        guard let a, actions.contains(a.type) else { return nil }
        switch a.type {
        case "open_url":
            guard let u = a.url, u.count < 400, URL(string: u)?.scheme == "https" else { return nil }
            return LiveAction(type: a.type, url: u)
        case "open_screen":
            guard let s = a.screen, ident(s) else { return nil }
            return LiveAction(type: a.type, screen: s)
        case "ask_ai", "copy":
            guard let t = a.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return LiveAction(type: a.type, text: String(t.prefix(600)))
        default:
            return LiveAction(type: a.type)
        }
    }

    static func node(_ n: LiveNode, depth: Int, budget: Budget) -> LiveNode? {
        guard depth <= 6, budget.nodes < 150, types.contains(n.t) else { return nil }
        budget.nodes += 1
        var o = LiveNode(t: n.t)
        o.text = cut(n.text, 600)
        o.style = n.style.flatMap { styles.contains($0) ? $0 : nil }
        o.color = n.color.flatMap { colors.contains($0) ? $0 : nil }
        o.align = n.align.flatMap { aligns.contains($0) ? $0 : nil }
        o.symbol = symbol(n.symbol)
        o.title = cut(n.title, 120)
        o.subtitle = cut(n.subtitle, 240)
        o.icon = symbol(n.icon)
        o.action = action(n.action)
        o.axis = n.axis == "h" ? "h" : (n.axis == "v" ? "v" : nil)
        o.size = n.size.map { min(max($0, 0), 120) }
        o.key = n.key.flatMap { ident($0) ? $0 : nil }
        o.on = n.on
        o.children = n.children.map { Array($0.prefix(40).compactMap { node($0, depth: depth + 1, budget: budget) }) }
        o.items = n.items.map { Array($0.prefix(30).map { LiveItem(title: String($0.title.prefix(120)), subtitle: cut($0.subtitle, 240), icon: symbol($0.icon), action: action($0.action)) }) }
        o.rows = n.rows.map { Array($0.prefix(30).map { LiveKV(k: String($0.k.prefix(80)), v: String($0.v.prefix(240))) }) }
        return o
    }
}

extension LiveScreen {
    func sanitized() -> LiveScreen? {
        guard LiveUI.ident(id), !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let budget = LiveUI.Budget()
        let shows = (show ?? ["sidebar"]).filter { $0 == "sidebar" || $0 == "home" }
        return LiveScreen(id: id, title: String(title.prefix(60)), icon: LiveUI.symbol(icon), show: shows.isEmpty ? ["sidebar"] : shows,
                          body: Array(body.prefix(40).compactMap { LiveUI.node($0, depth: 0, budget: budget) }))
    }
}

extension Notification.Name { static let liveAskAI = Notification.Name("dtx.live.askAI") }

// MARK: - Drawing

private func liveColor(_ name: String?, _ fallback: Color) -> Color {
    switch name {
    case "accent": return .dtAccent
    case "secondary": return .secondary
    case "white": return .white
    case "red": return .red
    case "green": return .green
    case "orange": return .orange
    case "yellow": return .yellow
    case "blue": return .blue
    default: return fallback
    }
}
private func liveAlign(_ a: String?) -> Alignment { a == "center" ? .center : (a == "right" ? .trailing : .leading) }

struct LiveNodeView: View {
    let node: LiveNode
    let screenID: String
    let run: (LiveAction) -> Void

    var body: some View {
        switch node.t {
        case "text":
            Text(node.text ?? "")
                .font(font(node.style))
                .foregroundStyle(liveColor(node.color, node.style == "caption" ? .secondary : .white))
                .multilineTextAlignment(node.align == "center" ? .center : (node.align == "right" ? .trailing : .leading))
                .frame(maxWidth: .infinity, alignment: liveAlign(node.align))
        case "image":
            Image(systemName: node.symbol ?? "questionmark")
                .font(.system(size: CGFloat(node.size ?? 30)))
                .foregroundStyle(liveColor(node.color, .dtAccent))
                .frame(maxWidth: .infinity, alignment: liveAlign(node.align))
        case "button":
            Button { if let a = node.action { run(a) } } label: { buttonLabel }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: liveAlign(node.align))
        case "stack":
            if node.axis == "h" {
                HStack(alignment: .center, spacing: 10) { kids }
            } else {
                VStack(alignment: .leading, spacing: 10) { kids }
            }
        case "card":
            VStack(alignment: .leading, spacing: 10) {
                if let t = node.title ?? node.text { Text(t).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white) }
                kids
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.115)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5))
        case "divider":
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5)
        case "spacer":
            Color.clear.frame(height: CGFloat(node.size ?? 12))
        case "list":
            VStack(spacing: 0) {
                ForEach(Array((node.items ?? []).enumerated()), id: \.offset) { i, item in
                    Button { if let a = item.action { run(a) } } label: {
                        HStack(spacing: 12) {
                            if let ic = item.icon { Image(systemName: ic).font(.system(size: 18)).foregroundStyle(Color.dtAccent).frame(width: 26) }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.system(size: 16)).foregroundStyle(.white)
                                if let s = item.subtitle { Text(s).font(.system(size: 13)).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 6)
                            if item.action != nil { Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(white: 0.45)) }
                        }
                        .padding(.vertical, 11).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if i < (node.items ?? []).count - 1 { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5) }
                }
            }
        case "kv":
            VStack(spacing: 6) {
                ForEach(Array((node.rows ?? []).enumerated()), id: \.offset) { _, r in
                    HStack(alignment: .top) {
                        Text(r.k).font(.system(size: 14)).foregroundStyle(.secondary)
                        Spacer(minLength: 10)
                        Text(r.v).font(.system(size: 14)).foregroundStyle(.white).multilineTextAlignment(.trailing)
                    }
                }
            }
        case "badge":
            Text(node.text ?? "").font(.caption.bold()).foregroundStyle(liveColor(node.color, .dtAccent))
                .padding(.horizontal, 9).padding(.vertical, 4).background(Capsule().fill(Color.white.opacity(0.08)))
                .frame(maxWidth: .infinity, alignment: liveAlign(node.align))
        case "toggle":
            LiveToggleView(screenID: screenID, key: node.key ?? "toggle", title: node.title ?? node.text ?? "", initial: node.on ?? false)
        default:
            EmptyView()
        }
    }

    private var kids: some View {
        ForEach(Array((node.children ?? []).enumerated()), id: \.offset) { _, c in
            LiveNodeView(node: c, screenID: screenID, run: run)
        }
    }

    private func font(_ s: String?) -> Font {
        switch s {
        case "title": return .system(size: 28, weight: .bold)
        case "headline": return .system(size: 18, weight: .semibold)
        case "caption": return .system(size: 13)
        case "mono": return .system(size: 14, design: .monospaced)
        default: return .system(size: 16)
        }
    }

    @ViewBuilder private var buttonLabel: some View {
        let content = HStack(spacing: 6) {
            if let i = node.icon { Image(systemName: i) }
            Text(node.title ?? node.text ?? "Open")
        }
        .font(.system(size: 15, weight: .semibold))
        switch node.style {
        case "glass":
            content.foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 10).aiGlass(Capsule())
        case "plain":
            content.foregroundStyle(Color.dtAccent)
        default:
            content.foregroundStyle(Color.dtOnAccent).padding(.horizontal, 16).padding(.vertical, 10).background(Capsule().fill(Color.dtAccent))
        }
    }
}

/// A switch whose state stays on this phone (UserDefaults), per screen and key.
struct LiveToggleView: View {
    let screenID: String
    let key: String
    let title: String
    let initial: Bool
    @State private var on = false

    private var storeKey: String { "dt.live.ui.\(screenID).\(key)" }
    var body: some View {
        Toggle(title, isOn: Binding(get: { on }, set: { on = $0; UserDefaults.standard.set($0, forKey: storeKey) }))
            .tint(.dtAccent).foregroundStyle(.white)
            .onAppear { on = UserDefaults.standard.object(forKey: storeKey) as? Bool ?? initial }
    }
}

/// The nodes of one screen (no scroll view), so it can sit inside a sheet or on the empty chat.
struct LiveScreenBody: View {
    let screen: LiveScreen
    var screens: [LiveScreen]? = nil
    var onClose: (() -> Void)? = nil
    @State private var nested: LiveScreen?
    private var all: [LiveScreen] { screens ?? LiveSync.shared.config.screens ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(screen.body.enumerated()), id: \.offset) { _, n in
                LiveNodeView(node: n, screenID: screen.id, run: run)
            }
        }
        .sheet(item: $nested) { s in LiveScreenSheet(screen: s, screens: screens) }
    }

    private func run(_ a: LiveAction) {
        switch a.type {
        case "open_url": if let u = a.url.flatMap(URL.init(string:)), u.scheme == "https" { UIApplication.shared.open(u) }
        case "open_screen": if let id = a.screen, let s = all.first(where: { $0.id == id }) { nested = s }
        case "ask_ai":
            if let t = a.text { onClose?(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { NotificationCenter.default.post(name: .liveAskAI, object: t) } }
        case "copy": if let t = a.text { UIPasteboard.general.string = t }
        case "sync": Task { await LiveSync.shared.sync() }
        case "close": onClose?()
        default: break
        }
    }
}

struct LiveScreenSheet: View {
    let screen: LiveScreen
    var screens: [LiveScreen]? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LiveScreenBody(screen: screen, screens: screens, onClose: { dismiss() }).padding(16)
            }
            .background(AppBackground())
            .navigationTitle(screen.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .tint(.dtAccent)
    }
}

/// What the empty new-chat screen shows when a release marked a screen as "home".
@MainActor enum LiveHome {
    static var screen: LiveScreen? { LiveSync.shared.config.screens?.first { ($0.show ?? []).contains("home") } }
}
