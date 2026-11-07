import SwiftUI
import UIKit

/// The accent colour the person picked by asking Ai-Decrypt ("change the app from green to orange").
/// It is saved on the device and beats an accent that a live release sets.
final class UserTheme: ObservableObject {
    static let shared = UserTheme()
    private static let key = "dtx.theme.accent"

    /// bumps on every change so open screens can rebuild with the new colour
    @Published private(set) var rev = 0
    /// bumps on gradual changes (the auto colour cycle): views recolour when they next draw, but nothing is rebuilt or dismissed
    @Published private(set) var tick = 0
    private(set) var hex: String?

    private init() { hex = UserDefaults.standard.string(forKey: Self.key) }

    static var accent: Color? { shared.hex.flatMap { AppPalette.color(hex: $0) } }

    /// black or white label colour that stays readable on the accent
    static var onAccent: Color {
        guard let h = shared.hex, let c = AppPalette.rgb(hex: h) else { return .black }
        return AppPalette.luma(c) > 0.6 ? .black : .white
    }

    func set(hex: String?, rebuild: Bool = true) {
        self.hex = hex
        if let hex { UserDefaults.standard.set(hex, forKey: Self.key) }
        else { UserDefaults.standard.removeObject(forKey: Self.key) }
        if rebuild { rev += 1 } else { tick += 1 }
    }
}

enum AppPalette {
    /// Colours chosen to read well on the app's dark background.
    static let names: [String: String] = [
        "orange": "F0842C", "red": "FF4D4D", "coral": "FF7A6B", "peach": "FFB38A", "pink": "FF5FA2", "hot pink": "FF3D8B",
        "magenta": "E85CFF", "purple": "B07CFF", "violet": "9B7BFF", "indigo": "7C8CFF", "blue": "4DA3FF", "sky": "6CC6FF",
        "sky blue": "6CC6FF", "cyan": "33D6FF", "teal": "2DD4BF", "mint": "5CF2C0", "emerald": "34D399", "yellow": "FAD649",
        "gold": "F5C542", "amber": "FFB020", "white": "F2F2F2", "silver": "C9CED6",
    ]
    /// asking for these puts the original lime green back
    static let resetNames: Set<String> = ["green", "lime", "lime green", "default", "original", "reset", "normal", "stock"]

    static func hex(for input: String) -> String? {
        var t = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for suffix in [" colour", " color"] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        if let h = names[t] { return h }
        var h = t
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, h.allSatisfy({ $0.isHexDigit }) else { return nil }
        return h.uppercased()
    }

    static func rgb(hex: String) -> (r: Double, g: Double, b: Double)? {
        guard let v = UInt32(hex, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    static func luma(_ c: (r: Double, g: Double, b: Double)) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }

    static func color(hex: String) -> Color? {
        guard let c = rgb(hex: hex) else { return nil }
        return Color(red: c.r, green: c.g, blue: c.b)
    }
}

/// Lets the chat model recolour the whole app. The text model calls the `set_app_theme` function; the vision model
/// (which can't call functions) writes `[THEME]orange[/THEME]` instead.
enum AiThemeTool {
    static let name = "set_app_theme"

    static let schema: [String: Any] = [
        "type": "function",
        "function": [
            "name": "set_app_theme",
            "description": "Changes the accent colour of this whole app (buttons, highlights, icons, tab bar, chat). Call it whenever the person asks to change, switch, recolour or theme the app or its colour, e.g. \"change this app from green to orange\". Use \"default\" to restore the original lime green.",
            "parameters": [
                "type": "object",
                "properties": [
                    "color": ["type": "string", "description": "The new accent colour: a name (orange, red, coral, pink, purple, violet, blue, sky, cyan, teal, mint, yellow, gold, white) or a hex such as #FF7A00. \"default\" restores the original."],
                ],
                "required": ["color"],
            ] as [String: Any],
        ] as [String: Any],
    ]

    @MainActor static func run(arguments: String) -> String {
        var color = ""
        if let d = arguments.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            color = (o["color"] as? String) ?? (o["colour"] as? String) ?? ""
        }
        return apply(color).message
    }

    @MainActor static func apply(_ input: String) -> (ok: Bool, message: String) {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if AppPalette.resetNames.contains(t) {
            UserTheme.shared.set(hex: nil)
            return (true, "The accent colour is back to the original lime green, applied across the whole app.")
        }
        guard let hex = AppPalette.hex(for: input), let rgb = AppPalette.rgb(hex: hex) else {
            return (false, "Couldn't use \"\(input)\" as a colour. Use a name (orange, red, pink, purple, blue, cyan, teal, mint, yellow, white) or a hex like #FF7A00.")
        }
        if AppPalette.luma(rgb) < 0.28 {
            return (false, "#\(hex) is too dark to read on the app's dark background. Pick a lighter shade.")
        }
        UserTheme.shared.set(hex: hex)
        return (true, "The app's accent colour is now \(t) (#\(hex)) and has been applied everywhere: buttons, highlights, icons, the tab bar and this chat.")
    }

    /// `[THEME]orange[/THEME]` → "orange"
    static func extractDirective(_ text: String) -> String? {
        guard let r = text.range(of: #"\[THEME\]([\s\S]*?)\[/THEME\]"#, options: .regularExpression) else { return nil }
        let inner = text[r].replacingOccurrences(of: "[THEME]", with: "").replacingOccurrences(of: "[/THEME]", with: "")
        let v = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}
