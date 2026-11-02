import SwiftUI

extension Color {
    static let dtBG = Color(red: 0.02, green: 0.02, blue: 0.028)
    static let dtCard = Color(red: 0.075, green: 0.07, blue: 0.082)
    static let dtLine = Color.white.opacity(0.10)
    static let dtAccent = Color(red: 1.0, green: 0.541, blue: 0.122)
    static let dtGreen = Color(red: 0.18, green: 0.75, blue: 0.45)
}

/// The floating glass look: a dark translucent panel with an orange glow edge.
struct CardStyle: ViewModifier {
    var radius: CGFloat = 22
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.07), Color.white.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.black.opacity(0.35)))
            )
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(LinearGradient(colors: [Color.dtAccent.opacity(0.55), Color.dtAccent.opacity(0.12), Color.dtAccent.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .shadow(color: Color.dtAccent.opacity(0.18), radius: 12, y: 2)
    }
}
extension View { func card() -> some View { modifier(CardStyle()) } }

/// A capsule with the same glow, for the header, search bar and tab bar.
struct GlowCapsule: ViewModifier {
    var strong = false
    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(Color.black.opacity(0.55)).background(.ultraThinMaterial, in: Capsule()))
            .overlay(Capsule().stroke(LinearGradient(colors: [Color.dtAccent.opacity(strong ? 0.9 : 0.55), Color.dtAccent.opacity(0.15), Color.dtAccent.opacity(strong ? 0.7 : 0.35)], startPoint: .leading, endPoint: .trailing), lineWidth: strong ? 1.5 : 1))
            .shadow(color: Color.dtAccent.opacity(strong ? 0.35 : 0.2), radius: strong ? 16 : 10)
    }
}
extension View { func glowCapsule(strong: Bool = false) -> some View { modifier(GlowCapsule(strong: strong)) } }

/// Near-black with soft orange glows, behind every screen.
struct AppBackground: View {
    var body: some View {
        ZStack {
            Color.dtBG
            RadialGradient(colors: [Color.dtAccent.opacity(0.22), .clear], center: .topTrailing, startRadius: 10, endRadius: 420)
            RadialGradient(colors: [Color.dtAccent.opacity(0.16), .clear], center: .bottomLeading, startRadius: 10, endRadius: 460)
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
