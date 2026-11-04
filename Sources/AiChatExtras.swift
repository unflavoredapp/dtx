import SwiftUI
import UIKit
import ImageIO

// MARK: - Colour wheel intent + tool

/// Decides when a message should pop the colour wheel straight into the conversation, and gives the model a
/// `show_color_picker` function (the vision model writes `[COLORWHEEL]#FF7A00[/COLORWHEEL]` instead).
enum AiColorIntent {
    static let toolName = "show_color_picker"

    static let schema: [String: Any] = [
        "type": "function",
        "function": [
            "name": toolName,
            "description": "Shows an interactive colour wheel (hue wheel, brightness slider, hex field) inside the chat so the person can pick a colour and apply it to the app. Call it when they ask for a colour wheel / colour picker, want to choose or fine-tune a colour themselves, or give a hex code.",
            "parameters": [
                "type": "object",
                "properties": [
                    "hex": ["type": "string", "description": "Optional starting colour as hex, e.g. #FF7A00."],
                ],
            ] as [String: Any],
        ] as [String: Any],
    ]

    /// A hex code such as #FF7A00 / #f70, or a message that is only a hex code ("ff7a00").
    static func hex(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #"#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})\b"#, options: .regularExpression) {
            return AppPalette.hex(for: String(t[r]))
        }
        if t.count == 6, t.allSatisfy({ $0.isHexDigit }), t.contains(where: { $0.isNumber }) {
            return AppPalette.hex(for: t)
        }
        return nil
    }

    /// Returns the colour to open the wheel on (current accent when none was typed), or nil for "not a colour-wheel message".
    @MainActor static func detect(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 140, !t.contains("```"), !t.hasPrefix("--- file:") else { return nil }
        let lower = t.lowercased()
        let asked = ["color wheel", "colour wheel", "color picker", "colour picker", "hex wheel", "hex picker",
                     "color pallet", "colour palette", "color palette", "hex code", "pick a color", "pick a colour",
                     "pick color", "pick colour", "choose a color", "choose a colour", "hex color", "hex colour"]
            .contains { lower.contains($0) }
        let typed = hex(in: t)
        guard asked || typed != nil else { return nil }
        return typed ?? UserTheme.shared.hex ?? "B6FF3C"
    }

    static func extractDirective(_ text: String) -> (hex: String?, rest: String)? {
        guard let r = text.range(of: #"\[COLORWHEEL\]([\s\S]*?)\[/COLORWHEEL\]"#, options: .regularExpression) else { return nil }
        let inner = text[r].replacingOccurrences(of: "[COLORWHEEL]", with: "").replacingOccurrences(of: "[/COLORWHEEL]", with: "")
        var rest = text; rest.removeSubrange(r)
        return (AppPalette.hex(for: inner), rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func argHex(_ arguments: String) -> String? {
        guard let d = arguments.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let h = o["hex"] as? String else { return nil }
        return AppPalette.hex(for: h)
    }
}

// MARK: - Colour wheel card

private func hsbToHex(h: Double, s: Double, b: Double) -> String {
    var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, a: CGFloat = 0
    UIColor(hue: h, saturation: s, brightness: b, alpha: 1).getRed(&r, green: &g, blue: &bl, alpha: &a)
    return String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((bl * 255).rounded()))
}

private func hexToHSB(_ hex: String) -> (h: Double, s: Double, b: Double)? {
    guard let c = AppPalette.rgb(hex: hex) else { return nil }
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    return (Double(h), Double(s), Double(b))
}

/// Hue/saturation wheel + brightness slider + hex field, shown inline in the chat. Apply recolours the whole app.
@MainActor
struct AiColorPickerCard: View {
    let initialHex: String
    let onApplied: (String) -> Void

    @State private var hue = 0.25
    @State private var sat = 0.8
    @State private var bri = 1.0
    @State private var field = ""
    @State private var note: String?
    @State private var noteOK = true
    @FocusState private var fieldFocused: Bool

    private var hex: String { hsbToHex(h: hue, s: sat, b: bri) }
    private var color: Color { Color(hue: hue, saturation: sat, brightness: bri) }
    private var tooDark: Bool { (AppPalette.rgb(hex: hex).map(AppPalette.luma) ?? 1) < 0.28 }

    var body: some View {
        VStack(spacing: 14) {
            wheel
                .frame(width: 210, height: 210)

            VStack(spacing: 4) {
                HStack {
                    Text("Brightness").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((bri * 100).rounded()))%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                brightnessSlider.frame(height: 28)
            }

            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color)
                    .frame(width: 44, height: 44)
                    .overlay(Text("Aa").font(.system(size: 15, weight: .bold)).foregroundStyle(
                        (AppPalette.rgb(hex: hex).map(AppPalette.luma) ?? 1) > 0.6 ? Color.black : Color.white))
                HStack(spacing: 2) {
                    Text("#").foregroundStyle(.secondary)
                    TextField("FF7A00", text: $field)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .focused($fieldFocused)
                        .onChange(of: field) { v in
                            let clean = String(v.uppercased().filter { $0.isHexDigit }.prefix(6))
                            if clean != v { field = clean; return }
                            if clean.count == 6, clean != hex, let hsb = hexToHSB(clean) {
                                hue = hsb.h; sat = hsb.s; bri = hsb.b
                            }
                        }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
            }

            if tooDark {
                Text("Too dark to read on the app's dark background — raise the brightness.")
                    .font(.caption2).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Button {
                    fieldFocused = false
                    let r = AiThemeTool.apply("default")
                    note = r.message; noteOK = r.ok
                    onApplied("B6FF3C")
                } label: {
                    Text("Reset").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
                }
                Button {
                    fieldFocused = false
                    let h = hex
                    let r = AiThemeTool.apply("#" + h)
                    note = r.ok ? "Applied #\(h) across the whole app." : r.message
                    noteOK = r.ok
                    if r.ok { onApplied(h) }
                } label: {
                    Text("Apply").font(.subheadline.weight(.bold)).foregroundStyle(tooDark ? Color.white.opacity(0.5) : Color.dtOnAccent)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tooDark ? Color.white.opacity(0.08) : color))
                }
                .disabled(tooDark)
            }

            if let note {
                Text(note).font(.caption2).foregroundStyle(noteOK ? Color.secondary : Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.045)))
        .onAppear {
            if let hsb = hexToHSB(initialHex) { hue = hsb.h; sat = hsb.s; bri = hsb.b }
            field = initialHex.uppercased()
        }
    }

    private func sync() { if !fieldFocused { field = hex } }

    private var wheel: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            let r = d / 2
            ZStack {
                Circle().fill(AngularGradient(
                    gradient: Gradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { Color(hue: $0, saturation: 1, brightness: 1) }),
                    center: .center, angle: .degrees(0)))
                Circle().fill(RadialGradient(colors: [.white, Color.white.opacity(0)], center: .center, startRadius: 0, endRadius: r))
                Circle().fill(Color.black.opacity(1 - bri))
                Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                // thumb
                let ang = hue * 2 * .pi
                let dist = sat * Double(r)
                Circle()
                    .fill(color)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .position(x: r + CGFloat(cos(ang) * dist), y: r + CGFloat(sin(ang) * dist))
            }
            .frame(width: d, height: d)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let dx = Double(g.location.x - r), dy = Double(g.location.y - r)
                var a = atan2(dy, dx); if a < 0 { a += 2 * .pi }
                hue = a / (2 * .pi)
                sat = min(1, sqrt(dx * dx + dy * dy) / Double(r))
                fieldFocused = false
                sync()
            })
        }
    }

    private var brightnessSlider: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: [.black, Color(hue: hue, saturation: sat, brightness: 1)], startPoint: .leading, endPoint: .trailing))
                Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                Circle().fill(Color.white).frame(width: 24, height: 24).shadow(radius: 2)
                    .offset(x: max(0, min(w - 24, CGFloat(bri) * (w - 24))))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                bri = Double(max(0, min(1, (g.location.x - 12) / max(1, w - 24))))
                fieldFocused = false
                sync()
            })
        }
    }
}

// MARK: - GIFs

struct GiphyGIF: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    /// animated, sized for chat bubbles
    let url: String
    /// still frame for the picker grid
    let still: String
    let width: Double
    let height: Double
}

/// GIPHY search. The key can be overridden with UserDefaults "dtx.giphy.key" or an Info.plist "GIPHY_API_KEY";
/// the fallback is GIPHY's shared public beta key (rate limited — put a real key in for production).
enum GiphyAPI {
    private static var key: String {
        if let k = UserDefaults.standard.string(forKey: "dtx.giphy.key"), !k.isEmpty { return k }
        if let k = Bundle.main.object(forInfoDictionaryKey: "GIPHY_API_KEY") as? String, !k.isEmpty { return k }
        return "dc6zaTOxFJmzC"
    }

    static func search(_ query: String, limit: Int = 24) async throws -> [GiphyGIF] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var comps = URLComponents(string: q.isEmpty ? "https://api.giphy.com/v1/gifs/trending" : "https://api.giphy.com/v1/gifs/search")!
        var items = [URLQueryItem(name: "api_key", value: key), URLQueryItem(name: "limit", value: String(limit)),
                     URLQueryItem(name: "rating", value: "pg-13")]
        if !q.isEmpty { items.append(URLQueryItem(name: "q", value: q)); items.append(URLQueryItem(name: "lang", value: "en")) }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!, timeoutInterval: 15)
        req.httpMethod = "GET"
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ApiError.server("GIF search answered with error \(http.statusCode).", http.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { g in
            guard let id = g["id"] as? String, let imgs = g["images"] as? [String: Any] else { return nil }
            func pick(_ names: [String]) -> [String: Any]? { names.compactMap { imgs[$0] as? [String: Any] }.first { ($0["url"] as? String)?.isEmpty == false } }
            guard let anim = pick(["fixed_height_downsampled", "fixed_height", "downsized"]),
                  let url = anim["url"] as? String else { return nil }
            let still = (pick(["fixed_width_still", "fixed_height_still", "downsized_still"])?["url"] as? String) ?? url
            let w = Double((anim["width"] as? String) ?? "") ?? 200
            let h = Double((anim["height"] as? String) ?? "") ?? 200
            let title = ((g["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return GiphyGIF(id: id, title: title.isEmpty ? "GIF" : title, url: url, still: still, width: w, height: h)
        }
    }
}

/// Lets the chat model reply with a GIF: the text model calls `send_gif`; the vision model writes `[GIF]celebration[/GIF]`.
enum AiGifTool {
    static let name = "send_gif"

    static let schema: [String: Any] = [
        "type": "function",
        "function": [
            "name": name,
            "description": "Sends an animated GIF into the chat. Use it for reactions, celebrations, jokes and moods when it fits (and when the person asks for a GIF). Don't overuse it. After it runs, add at most one short line.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "A short GIPHY search, e.g. \"mind blown\", \"happy dance\", \"thumbs up\"."],
                ],
                "required": ["query"],
            ] as [String: Any],
        ] as [String: Any],
    ]

    static func extractQuery(_ arguments: String) -> String {
        guard let d = arguments.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "" }
        return ((o["query"] as? String) ?? (o["q"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractDirective(_ text: String) -> (query: String, rest: String)? {
        guard let r = text.range(of: #"\[GIF\]([\s\S]*?)\[/GIF\]"#, options: .regularExpression) else { return nil }
        let inner = text[r].replacingOccurrences(of: "[GIF]", with: "").replacingOccurrences(of: "[/GIF]", with: "")
        var rest = text; rest.removeSubrange(r)
        let q = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? nil : (q, rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// One of the top few results (so repeating a request doesn't always give the identical GIF).
    static func find(_ query: String) async throws -> GiphyGIF? {
        let hits = try await GiphyAPI.search(query, limit: 8)
        return hits.prefix(5).randomElement() ?? hits.first
    }
}

enum GIFDecoder {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for urlString: String) async -> UIImage? {
        if let hit = cache.object(forKey: urlString as NSString) { return hit }
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let img = await Task.detached(priority: .utility) { decode(data) }.value
        if let img { cache.setObject(img, forKey: urlString as NSString) }
        return img
    }

    static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return CGImageSourceCreateImageAtIndex(source, 0, nil).map { UIImage(cgImage: $0) } }
        let step = max(1, count / 90)          // keep memory sane on very long GIFs
        var frames: [UIImage] = []
        var total = 0.0
        var i = 0
        while i < count {
            if let cg = CGImageSourceCreateImageAtIndex(source, i, nil) {
                var delay = 0.1
                if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any],
                   let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                    delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
                    if delay < 0.02 { delay = 0.1 }
                }
                total += delay * Double(step)
                frames.append(UIImage(cgImage: cg))
            }
            i += step
        }
        return UIImage.animatedImage(with: frames, duration: max(total, 0.1))
    }
}

private struct GIFImageView: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFit
        v.clipsToBounds = true
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.image = image
        return v
    }
    func updateUIView(_ v: UIImageView, context: Context) { if v.image !== image { v.image = image } }
}

/// A remote animated GIF, loaded once and cached.
struct RemoteGIF: View {
    let url: String
    var maxWidth: CGFloat = 240
    var maxHeight: CGFloat = 200
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                let s = image.size
                let scale = min(maxWidth / max(s.width, 1), maxHeight / max(s.height, 1), 1.5)
                GIFImageView(image: image)
                    .frame(width: s.width * scale, height: s.height * scale)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if failed {
                Label("GIF couldn't load", systemImage: "photo.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 160, height: 110)
                    .overlay(ProgressView())
            }
        }
        .task(id: url) {
            image = nil; failed = false
            if let img = await GIFDecoder.image(for: url) { image = img } else { failed = true }
        }
    }
}

/// Search sheet opened from the composer's + menu. Tapping a GIF sends it.
struct AiGifPickerSheet: View {
    let onPick: (GiphyGIF) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [GiphyGIF] = []
    @State private var loading = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?

    private let cols = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search GIFs", text: $query)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .onSubmit { run(delay: 0) }
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
                .padding(12)

                if let error {
                    Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 14)
                }
                ScrollView {
                    if loading && results.isEmpty { ProgressView().padding(40) }
                    LazyVGrid(columns: cols, spacing: 6) {
                        ForEach(results) { g in
                            Button { onPick(g); dismiss() } label: {
                                AsyncImage(url: URL(string: g.still)) { phase in
                                    switch phase {
                                    case .success(let img): img.resizable().scaledToFill()
                                    default: Color.white.opacity(0.06)
                                    }
                                }
                                .frame(height: 120)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    Text("Powered by GIPHY").font(.caption2).foregroundStyle(.secondary).padding(16)
                }
            }
            .background(AppBackground())
            .navigationTitle("GIFs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onChange(of: query) { _ in run(delay: 450) }
            .task { run(delay: 0) }
        }
        .tint(.dtAccent)
    }

    private func run(delay: Int) {
        searchTask?.cancel()
        searchTask = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
            guard !Task.isCancelled else { return }
            loading = true; error = nil
            do {
                let r = try await GiphyAPI.search(query)
                if !Task.isCancelled { results = r; if r.isEmpty { error = "No GIFs found." } }
            } catch {
                if !Task.isCancelled { self.error = "Couldn't reach GIPHY. \(error.localizedDescription)" }
            }
            loading = false
        }
    }
}

// MARK: - Emoji shortcodes

enum EmojiShortcodes {
    static let table: [String: String] = [
        "smile": "😄", "grin": "😁", "joy": "😂", "lol": "😂", "rofl": "🤣", "wink": "😉", "blush": "😊", "heart_eyes": "😍",
        "sunglasses": "😎", "cool": "😎", "thinking": "🤔", "sob": "😭", "cry": "😢", "angry": "😠", "rage": "😡", "scream": "😱",
        "sweat_smile": "😅", "sleepy": "😴", "nerd": "🤓", "party": "🥳", "partying_face": "🥳", "mind_blown": "🤯", "exploding_head": "🤯",
        "shrug": "🤷", "facepalm": "🤦", "pray": "🙏", "clap": "👏", "wave": "👋", "thumbsup": "👍", "+1": "👍", "thumbsdown": "👎", "-1": "👎",
        "ok_hand": "👌", "muscle": "💪", "eyes": "👀", "fire": "🔥", "sparkles": "✨", "star": "⭐", "boom": "💥", "zap": "⚡",
        "heart": "❤️", "broken_heart": "💔", "100": "💯", "rocket": "🚀", "tada": "🎉", "trophy": "🏆", "check": "✅",
        "white_check_mark": "✅", "x": "❌", "warning": "⚠️", "bulb": "💡", "lock": "🔒", "key": "🔑", "bug": "🐛", "gear": "⚙️",
        "wrench": "🔧", "hammer": "🔨", "package": "📦", "apple": "🍎", "iphone": "📱", "computer": "💻", "robot": "🤖",
        "skull": "💀", "ghost": "👻", "poop": "💩", "coffee": "☕", "pizza": "🍕", "beer": "🍺", "sun": "☀️", "moon": "🌙",
        "rainbow": "🌈", "snowflake": "❄️", "art": "🎨", "paint": "🎨", "lightning": "⚡", "hourglass": "⏳", "memo": "📝",
        "mag": "🔍", "link": "🔗", "pushpin": "📌", "bell": "🔔", "gift": "🎁", "crown": "👑", "gem": "💎", "ghost_face": "👻",
    ]

    /// `:fire:` → 🔥 (unknown codes stay as typed)
    static func expand(_ text: String) -> String {
        guard text.contains(":") else { return text }
        guard let re = try? NSRegularExpression(pattern: #":([a-z0-9_+\-]{1,24}):"#) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let code = ns.substring(with: m.range(at: 1))
            guard let e = table[code] else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + e
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
