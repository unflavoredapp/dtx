import SwiftUI
import UIKit

// MARK: - Block model + parser

enum MDBlock {
    case heading(Int, String)
    case paragraph(String)
    case bullet(Int, String)
    case numbered(Int, Int, String)
    case quote(String)
    case code(String?, String)
    case table([String], [[String]])
    case rule
}

enum MarkdownParser {
    static func parse(_ src: String) -> [MDBlock] {
        let lines = src.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [MDBlock] = []
        var para: [String] = []
        var i = 0

        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] }
        }
        func indentLevel(_ raw: String) -> Int {
            var n = 0
            for ch in raw { if ch == " " { n += 1 } else if ch == "\t" { n += 4 } else { break } }
            return min(3, n / 2)
        }

        while i < lines.count {
            let raw = lines[i]
            let t = raw.trimmingCharacters(in: .whitespaces)

            // fenced code
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                flush()
                let fence = String(t.prefix(3))
                let lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[i]); i += 1
                }
                i += 1
                out.append(.code(lang.isEmpty ? nil : lang, body.joined(separator: "\n")))
                continue
            }

            if t.isEmpty { flush(); i += 1; continue }

            // heading
            if t.hasPrefix("#") {
                let hashes = t.prefix(while: { $0 == "#" }).count
                if hashes <= 6, t.dropFirst(hashes).first == " " {
                    flush()
                    out.append(.heading(hashes, String(t.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)))
                    i += 1; continue
                }
            }

            // horizontal rule
            if t.count >= 3, let c = t.first, "-*_".contains(c), t.allSatisfy({ $0 == c || $0 == " " }), t.filter({ $0 == c }).count >= 3 {
                flush(); out.append(.rule); i += 1; continue
            }

            // quote
            if t.hasPrefix(">") {
                flush()
                var q: [String] = []
                while i < lines.count {
                    let tt = lines[i].trimmingCharacters(in: .whitespaces)
                    guard tt.hasPrefix(">") else { break }
                    var s = String(tt.dropFirst())
                    if s.hasPrefix(" ") { s.removeFirst() }
                    q.append(s); i += 1
                }
                out.append(.quote(q.joined(separator: "\n")))
                continue
            }

            // table
            if t.contains("|"), i + 1 < lines.count, isSeparator(lines[i + 1]) {
                flush()
                let head = cells(t)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let tt = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !tt.isEmpty, tt.contains("|") else { break }
                    rows.append(cells(tt)); i += 1
                }
                out.append(.table(head, rows))
                continue
            }

            // bullets
            var bulletText: String? = nil
            for mark in ["- ", "* ", "+ ", "• "] where t.hasPrefix(mark) { bulletText = String(t.dropFirst(2)); break }
            if let bt = bulletText {
                flush()
                out.append(.bullet(indentLevel(raw), bt))
                i += 1; continue
            }

            // numbered
            let digits = t.prefix(while: { $0.isNumber })
            if !digits.isEmpty, digits.count <= 3, let n = Int(digits) {
                let rest = t.dropFirst(digits.count)
                if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                    flush()
                    out.append(.numbered(indentLevel(raw), n, String(rest.dropFirst(2))))
                    i += 1; continue
                }
            }

            // continuation of the previous list item
            if para.isEmpty, raw.hasPrefix("  "), let last = out.last {
                switch last {
                case .bullet(let l, let s): out[out.count - 1] = .bullet(l, s + "\n" + t); i += 1; continue
                case .numbered(let l, let n, let s): out[out.count - 1] = .numbered(l, n, s + "\n" + t); i += 1; continue
                default: break
                }
            }

            para.append(t)
            i += 1
        }
        flush()
        return out
    }

    private static func cells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }
}

// MARK: - Code highlighting for Text

enum CodeHighlighter {
    private static var cache: [String: AttributedString] = [:]

    static func attributed(_ code: String, language: CodeLanguage, size: CGFloat = 12) -> AttributedString {
        let key = "\(language.label)|\(size)|\(code)"
        if let c = cache[key] { return c }
        var out = AttributedString(code)
        out.font = Font.system(size: size, design: .monospaced)
        out.foregroundColor = Color(uiColor: CodePalette.text)
        if language != .plain, !code.isEmpty, code.utf16.count < 20_000 {
            let storage = NSTextStorage(string: code)
            let full = NSRange(location: 0, length: storage.length)
            CodeSyntax.forLanguage(language).apply(to: storage, text: code, range: full)
            storage.enumerateAttribute(.foregroundColor, in: full, options: []) { v, r, _ in
                guard let c = v as? UIColor, let sr = Range(r, in: code),
                      let lo = AttributedString.Index(sr.lowerBound, within: out),
                      let hi = AttributedString.Index(sr.upperBound, within: out) else { return }
                out[lo..<hi].foregroundColor = Color(uiColor: c)
            }
        }
        if cache.count > 80 { cache.removeAll() }
        cache[key] = out
        return out
    }

    static func diff(_ code: String) -> AttributedString {
        var out = AttributedString()
        let lines = code.components(separatedBy: "\n")
        for (i, l) in lines.enumerated() {
            var a = AttributedString(l + (i < lines.count - 1 ? "\n" : ""))
            a.font = Font.system(size: 12, design: .monospaced)
            if l.hasPrefix("+") && !l.hasPrefix("+++") {
                a.foregroundColor = Color.green; a.backgroundColor = Color.green.opacity(0.14)
            } else if l.hasPrefix("-") && !l.hasPrefix("---") {
                a.foregroundColor = Color.red; a.backgroundColor = Color.red.opacity(0.14)
            } else if l.hasPrefix("@@") {
                a.foregroundColor = Color(uiColor: CodePalette.directive)
            } else {
                a.foregroundColor = Color(white: 0.78)
            }
            out.append(a)
        }
        return out
    }

    static func language(for tag: String?, code: String) -> CodeLanguage {
        switch (tag ?? "").lowercased() {
        case "objc", "objective-c", "objectivec", "objective-c++", "objcpp", "c", "cpp", "c++", "h", "m", "mm", "cc", "hpp", "cxx": return .cFamily
        case "logos", "x", "xm", "tweak": return .logos
        case "make", "makefile", "mk": return .make
        case "json", "jsonc": return .json
        case "xml", "plist", "html": return .xml
        case "": break
        default: return .plain
        }
        if code.contains("%hook") || code.contains("%orig") { return .logos }
        if code.contains(";") && code.contains("{") { return .cFamily }
        return .plain
    }
}

// MARK: - Rendering

struct MarkdownView: View {
    @Environment(\.fileRefs) private var refs
    private let blocks: [MDBlock]

    init(_ text: String) {
        blocks = MarkdownParser.parse(text)
    }

    private static let fileRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?<![\w/.\-])((?:[A-Za-z0-9_+\-]+/)*(?:[A-Za-z0-9_+\-]+\.(?:mm|m|hpp|h|cpp|cc|c|xmi|xm|xi|x|swift|plist|json|txt|mk)|Makefile))(?::(\d+)(?:[-–]\d+)?)?(?![\w])"#)

    /// Makes `Tweak.m`, `Classes/Foo.m:42` and `Foo.m:10-20` tappable when they name a file in the project.
    private static func linkify(_ a: inout AttributedString, refs: FileRefResolver) {
        guard let re = fileRegex else { return }
        let plain = String(a.characters)
        let ns = plain as NSString
        for m in re.matches(in: plain, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            guard let path = refs.resolve(name) else { continue }
            var items = [URLQueryItem(name: "p", value: path)]
            if m.range(at: 2).location != NSNotFound { items.append(URLQueryItem(name: "l", value: ns.substring(with: m.range(at: 2)))) }
            var c = URLComponents()
            c.scheme = "dtx-open"; c.host = "file"; c.queryItems = items
            guard let url = c.url, let sr = Range(m.range, in: plain),
                  let lo = AttributedString.Index(sr.lowerBound, within: a),
                  let hi = AttributedString.Index(sr.upperBound, within: a) else { continue }
            a[lo..<hi].link = url
            a[lo..<hi].foregroundColor = Color.dtAccent
            a[lo..<hi].underlineStyle = Text.LineStyle.single
        }
    }

    /// Inline markdown (bold, italic, code, links) as an AttributedString. With `refs`, project file names become tappable.
    static func inline(_ s: String, refs: FileRefResolver? = nil) -> AttributedString {
        var opts = AttributedString.MarkdownParsingOptions()
        opts.interpretedSyntax = .inlineOnlyPreservingWhitespace
        opts.failurePolicy = .returnPartiallyParsedIfPossible
        var a = (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
        var codeRanges: [Range<AttributedString.Index>] = []
        for run in a.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) { codeRanges.append(run.range) }
        }
        for r in codeRanges {
            a[r].font = Font.system(size: 13, weight: .medium, design: .monospaced)
            a[r].foregroundColor = Color(red: 1.0, green: 0.80, blue: 0.58)
            a[r].backgroundColor = Color.white.opacity(0.12)
        }
        if let refs { linkify(&a, refs: refs) }
        return a
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return Font.title3.bold()
        case 2: return Font.headline
        default: return Font.subheadline.bold()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                block(b)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(Color.dtAccent)
    }

    @ViewBuilder private func block(_ b: MDBlock) -> some View {
        switch b {
        case .heading(let level, let s):
            Text(Self.inline(s, refs: refs))
                .font(Self.headingFont(level))
                .padding(.top, level <= 2 ? 4 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .paragraph(let s):
            Text(Self.inline(s, refs: refs))
                .font(.callout).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .bullet(let level, let s):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(level == 0 ? "•" : "◦").foregroundStyle(Color.dtAccent).frame(width: 12)
                Text(Self.inline(s, refs: refs)).font(.callout).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(level) * 16)
        case .numbered(let level, let n, let s):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(n).").font(.callout.monospacedDigit()).foregroundStyle(Color.dtAccent)
                    .frame(minWidth: 22, alignment: .trailing)
                Text(Self.inline(s, refs: refs)).font(.callout).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(level) * 16)
        case .quote(let s):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.dtAccent.opacity(0.7)).frame(width: 3)
                Text(Self.inline(s, refs: refs)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .code(let lang, let body):
            MarkdownCodeBlock(lang: lang, code: body)
        case .table(let head, let rows):
            MarkdownTable(header: head, rows: rows)
        case .rule:
            Divider().overlay(Color.white.opacity(0.15))
        }
    }
}

struct MarkdownCodeBlock: View {
    let lang: String?
    let code: String
    @State private var copied = false

    private var isDiff: Bool { ["diff", "patch"].contains((lang ?? "").lowercased()) }

    var body: some View {
        let language = CodeHighlighter.language(for: lang, code: code)
        VStack(spacing: 0) {
            HStack {
                Text(isDiff ? "DIFF" : (lang?.uppercased() ?? (language == .plain ? "CODE" : language.label.uppercased())))
                    .font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Color.green : Color.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.04))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(isDiff ? CodeHighlighter.diff(code) : CodeHighlighter.attributed(code, language: language))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(10)
            }
        }
        .background(Color.black.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, h in
                        Text(MarkdownView.inline(h)).font(.caption.bold())
                    }
                }
                Divider().overlay(Color.white.opacity(0.15))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    GridRow {
                        ForEach(0..<header.count, id: \.self) { c in
                            Text(MarkdownView.inline(c < r.count ? r[c] : "")).font(.caption)
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Project file references

/// Maps a name found in text (`Tweak.m`, `Classes/Foo.m`) to a real path in the open job.
struct FileRefResolver {
    let files: [String]

    func resolve(_ raw: String) -> String? {
        let n = raw.hasPrefix("./") ? String(raw.dropFirst(2)) : raw
        if files.contains(n) { return n }
        let tail = files.filter { $0.hasSuffix("/" + n) }
        if let best = tail.min(by: { $0.count < $1.count }) { return best }
        let base = (n as NSString).lastPathComponent
        let same = files.filter { ($0 as NSString).lastPathComponent == base }
        return same.count == 1 ? same[0] : nil
    }
}

private struct FileRefKey: EnvironmentKey { static let defaultValue: FileRefResolver? = nil }
extension EnvironmentValues {
    var fileRefs: FileRefResolver? {
        get { self[FileRefKey.self] }
        set { self[FileRefKey.self] = newValue }
    }
}

/// Reads a `dtx-open://file?p=…&l=…` link made by `MarkdownView`.
func parseFileLink(_ url: URL) -> (path: String, line: Int?)? {
    guard url.scheme == "dtx-open", let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let p = c.queryItems?.first(where: { $0.name == "p" })?.value else { return nil }
    return (p, c.queryItems?.first(where: { $0.name == "l" })?.value.flatMap { Int($0) })
}
