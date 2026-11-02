import SwiftUI
import SafariServices

extension Color {
    static let dtBG = Color(red: 0.067, green: 0.075, blue: 0.098)
    static let dtCard = Color(red: 0.105, green: 0.113, blue: 0.145)
    static let dtLine = Color.white.opacity(0.10)
    static let dtAccent = Color(red: 1.0, green: 0.541, blue: 0.122)
    static let dtGreen = Color(red: 0.18, green: 0.75, blue: 0.45)
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(Color.dtCard)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.dtLine))
    }
}
extension View { func card() -> some View { modifier(CardStyle()) } }

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

/// A web page from the site (login, request form…) shown in a Safari sheet.
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

struct IdentifiedURL: Identifiable { let url: URL; var id: String { url.absoluteString } }
