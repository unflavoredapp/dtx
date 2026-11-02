import SwiftUI

extension Color {
    static let dtBG = Color.black
    static let dtCard = Color(red: 0.085, green: 0.085, blue: 0.095)
    static let dtLine = Color.white.opacity(0.10)
    static let dtAccent = Color(red: 0.64, green: 0.95, blue: 0.42)      // lime green
    static let dtGreen = Color(red: 0.64, green: 0.95, blue: 0.42)
    static let dtYellow = Color(red: 0.98, green: 0.84, blue: 0.28)
}

/// A dark panel with a thin light edge.
struct CardStyle: ViewModifier {
    var radius: CGFloat = 22
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(0.065)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 1))
    }
}
extension View { func card() -> some View { modifier(CardStyle()) } }

/// A capsule for the search field and small chips.
struct GlowCapsule: ViewModifier {
    var strong = false
    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(Color.white.opacity(strong ? 0.07 : 0.06)))
            .overlay(Capsule().stroke(Color.white.opacity(strong ? 0.16 : 0.1), lineWidth: 1))
    }
}
extension View { func glowCapsule(strong: Bool = false) -> some View { modifier(GlowCapsule(strong: strong)) } }

/// The main button: lime with black text.
struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration) }
    private struct Inner: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .foregroundStyle(Color.black)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.dtAccent))
                .opacity(!enabled ? 0.4 : (configuration.isPressed ? 0.8 : 1))
        }
    }
}

/// Neutral dark glass for the top and bottom bars.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = 28
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.black.opacity(0.4))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
    }
}
extension View { func glassPanel(radius: CGFloat = 28) -> some View { modifier(GlassPanel(radius: radius)) } }

/// Black with a very faint grid.
struct AppBackground: View {
    var body: some View {
        ZStack {
            Color.black
            Canvas { ctx, size in
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += 40 }
                var y: CGFloat = 0
                while y <= size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += 40 }
                ctx.stroke(path, with: .color(Color(red: 0.64, green: 0.95, blue: 0.42).opacity(0.045)), lineWidth: 0.5)
            }
        }
        .ignoresSafeArea()
    }
}

struct Pill: View {
    let text: String
    var tone: Color = .gray
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(tone)
            .background(tone.opacity(0.14))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(tone.opacity(0.4)))
    }
}

extension String {
    /// Percent-encodes everything that isn't a plain URL-safe character, so a link can sit inside another link's ?url= value.
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? self
    }
}
