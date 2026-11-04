import SwiftUI
import UIKit

// MARK: - Language

enum CodeLanguage {
    case cFamily, logos, make, json, xml, plain

    static func detect(_ path: String) -> CodeLanguage {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        if name == "makefile" || name == "gnumakefile" || ext == "mk" { return .make }
        switch ext {
        case "x", "xm", "xi", "xmi": return .logos
        case "m", "mm", "h", "hpp", "c", "cc", "cpp", "cxx", "hh": return .cFamily
        case "json": return .json
        case "plist", "xml", "entitlements": return .xml
        default: return .plain
        }
    }

    var label: String {
        switch self {
        case .cFamily: return "Objective-C"
        case .logos: return "Logos"
        case .make: return "Makefile"
        case .json: return "JSON"
        case .xml: return "XML"
        case .plain: return "Plain text"
        }
    }

    var autoIndent: Bool { self == .cFamily || self == .logos }
}

// MARK: - Palette

private func rgb(_ hex: UInt32) -> UIColor {
    UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

enum CodePalette {
    static let background = UIColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1)
    static let text = rgb(0xE8E8E8)
    static let comment = rgb(0x7F8C98)
    static let string = rgb(0xFC6A5D)
    static let number = rgb(0xD0BF69)
    static let keyword = rgb(0xFC5FA3)
    static let type = rgb(0x5DD8FF)
    static let call = rgb(0x67B7A4)
    static let preproc = rgb(0xFD8F3F)
    static let directive = rgb(0xBF8BFF)
    static let gutterBG = UIColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
    static let gutterLine = UIColor(white: 1, alpha: 0.08)
    static let gutterText = UIColor(white: 1, alpha: 0.32)
    static let currentLine = UIColor(white: 1, alpha: 0.055)
    static let findMatch = UIColor.systemYellow.withAlphaComponent(0.28)
    static let findCurrent = UIColor.systemOrange.withAlphaComponent(0.65)
}

// MARK: - Syntax

final class CodeSyntax {
    struct Rule { let regex: NSRegularExpression; let color: UIColor }

    let rules: [Rule]
    let postRules: [Rule]
    let tokenizer: NSRegularExpression?
    let commentColor: UIColor
    let stringColor: UIColor

    init(rules: [Rule], postRules: [Rule] = [], comment: String?, string: String?) {
        self.rules = rules
        self.postRules = postRules
        self.commentColor = CodePalette.comment
        self.stringColor = CodePalette.string
        if comment != nil || string != nil {
            let c = comment ?? "(?!)", s = string ?? "(?!)"
            self.tokenizer = try? NSRegularExpression(pattern: "(\(c))|(\(s))", options: [])
        } else {
            self.tokenizer = nil
        }
    }

    private static func rule(_ pattern: String, _ color: UIColor, _ opts: NSRegularExpression.Options = []) -> Rule? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return nil }
        return Rule(regex: re, color: color)
    }

    private static var cache: [String: CodeSyntax] = [:]

    static func forLanguage(_ lang: CodeLanguage) -> CodeSyntax {
        let key = lang.label
        if let c = cache[key] { return c }
        let s = build(lang)
        cache[key] = s
        return s
    }

    private static func build(_ lang: CodeLanguage) -> CodeSyntax {
        switch lang {
        case .cFamily, .logos:
            let keywords = #"\b(?:if|else|for|while|do|switch|case|default|break|continue|return|goto|sizeof|typedef|struct|union|enum|static|extern|const|volatile|inline|register|auto|void|self|super|nil|NULL|Nil|YES|NO|true|false|__block|__weak|__strong|__unsafe_unretained|__bridge|__bridge_retained|__bridge_transfer|__attribute__|nonatomic|atomic|strong|weak|copy|assign|retain|readonly|readwrite|class|namespace|template|typename|using|new|delete|this|try|catch|throw|nullable|nonnull|unsafe_unretained|NS_ASSUME_NONNULL_BEGIN|NS_ASSUME_NONNULL_END)\b"#
            let types = #"\b(?:int|char|short|long|float|double|unsigned|signed|bool|id|SEL|Class|BOOL|IMP|instancetype|Protocol|size_t|ssize_t|uintptr_t|intptr_t|NSObject|NSString|NSInteger|NSUInteger|CGFloat|va_list|dispatch_once_t|dispatch_queue_t|dispatch_block_t)\b"#
            var r: [Rule?] = [
                rule(#"\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()"#, CodePalette.call),
                rule(#"\b(?:0[xX][0-9a-fA-F]+|[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)[uUlLfF]*\b"#, CodePalette.number),
                rule(keywords, CodePalette.keyword),
                rule(types, CodePalette.type),
                rule(#"\b(?:NS|UI|CG|CA|CF|AV|WK|SK|MK|CL|CK|AU|SF|QL|OS|MP|PH|AD|LA)[A-Z][A-Za-z0-9_]*\b"#, CodePalette.type),
                rule(#"\b[A-Za-z_][A-Za-z0-9_]*_t\b"#, CodePalette.type),
                rule(#"@(?:interface|implementation|end|protocol|property|synthesize|dynamic|class|selector|encode|try|catch|finally|throw|autoreleasepool|synchronized|public|private|protected|package|optional|required|import|available|compatibility_alias|defs)\b"#, CodePalette.keyword),
            ]
            if lang == .logos {
                r.append(rule(#"%(?:hook|end|orig|new|ctor|dtor|group|init|subclass|class|config|property|log|c)\b"#, CodePalette.directive))
            }
            r.append(rule(#"^[ \t]*#[ \t]*[A-Za-z_]+[^\n]*"#, CodePalette.preproc, [.anchorsMatchLines]))
            return CodeSyntax(rules: r.compactMap { $0 }, comment: #"//[^\n]*|/\*[\s\S]*?(?:\*/|\z)"#,
                              string: #"@?"(?:[^"\\\n]|\\.)*"?|'(?:[^'\\\n]|\\.)*'?"#)
        case .make:
            let r: [Rule?] = [
                rule(#"^[A-Za-z0-9_.%/\-]+(?=\s*:)"#, CodePalette.type, [.anchorsMatchLines]),
                rule(#"^(?:-?include|ifeq|ifneq|ifdef|ifndef|else|endif|define|endef|export|override)\b"#, CodePalette.keyword, [.anchorsMatchLines]),
                rule(#"\$[({][^)}\n]*[)}]|\$[@<^?*%+|]"#, CodePalette.directive),
            ]
            return CodeSyntax(rules: r.compactMap { $0 }, comment: #"#[^\n]*"#, string: #""(?:[^"\\\n]|\\.)*"?|'[^'\n]*'?"#)
        case .json:
            let r: [Rule?] = [
                rule(#"\b(?:true|false|null)\b"#, CodePalette.keyword),
                rule(#"-?\b[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\b"#, CodePalette.number),
            ]
            let post: [Rule?] = [rule(#""(?:[^"\\\n]|\\.)*"(?=\s*:)"#, CodePalette.type)]
            return CodeSyntax(rules: r.compactMap { $0 }, postRules: post.compactMap { $0 }, comment: nil, string: #""(?:[^"\\\n]|\\.)*"?"#)
        case .xml:
            let r: [Rule?] = [rule(#"</?[A-Za-z_][^>]*>|<\?[\s\S]*?\?>|<![A-Z][^>]*>"#, CodePalette.type)]
            return CodeSyntax(rules: r.compactMap { $0 }, comment: #"<!--[\s\S]*?(?:-->|\z)"#, string: nil)
        case .plain:
            return CodeSyntax(rules: [], comment: nil, string: nil)
        }
    }

    func apply(to storage: NSTextStorage, text: String, range: NSRange) {
        storage.addAttribute(.foregroundColor, value: CodePalette.text, range: range)
        for r in rules {
            r.regex.enumerateMatches(in: text, options: [], range: range) { m, _, _ in
                if let m = m, m.range.length > 0 { storage.addAttribute(.foregroundColor, value: r.color, range: m.range) }
            }
        }
        if let tk = tokenizer {
            tk.enumerateMatches(in: text, options: [], range: range) { m, _, _ in
                guard let m = m, m.range.length > 0 else { return }
                let isComment = m.range(at: 1).location != NSNotFound
                storage.addAttribute(.foregroundColor, value: isComment ? self.commentColor : self.stringColor, range: m.range)
            }
        }
        for r in postRules {
            r.regex.enumerateMatches(in: text, options: [], range: range) { m, _, _ in
                if let m = m, m.range.length > 0 { storage.addAttribute(.foregroundColor, value: r.color, range: m.range) }
            }
        }
    }
}

// MARK: - Gutter

final class CodeGutterView: UIView {
    weak var tv: CodeTextView?
    private let para: NSParagraphStyle = {
        let p = NSMutableParagraphStyle(); p.alignment = .right; return p
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func draw(_ rect: CGRect) {
        guard let tv = tv, let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(CodePalette.gutterBG.cgColor)
        ctx.fill(bounds)
        ctx.setFillColor(CodePalette.gutterLine.cgColor)
        ctx.fill(CGRect(x: bounds.width - 0.5, y: 0, width: 0.5, height: bounds.height))

        let lm = tv.layoutManager, tc = tv.textContainer
        let inset = tv.textContainerInset, off = tv.contentOffset
        let ns: NSString = tv.textStorage.mutableString
        let cur = tv.currentLineNumber
        let font = tv.numberFont

        func drawNumber(_ n: Int, y: CGFloat, h: CGFloat) {
            var color: UIColor = (n == cur) ? tv.tintColor : CodePalette.gutterText
            if let sev = tv.markers[n] {
                let mc: UIColor = sev >= 2 ? .systemRed : .systemYellow
                color = mc
                ctx.setFillColor(mc.cgColor)
                ctx.fillEllipse(in: CGRect(x: 4, y: y + (h - 6) / 2, width: 6, height: 6))
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
            let ty = y + (h - font.lineHeight) / 2
            (String(n) as NSString).draw(in: CGRect(x: 0, y: ty, width: bounds.width - 8, height: font.lineHeight), withAttributes: attrs)
        }

        if ns.length == 0 {
            drawNumber(1, y: inset.top - off.y, h: tv.codeFont.lineHeight)
            return
        }

        let vis = CGRect(x: 0, y: off.y - inset.top, width: max(tc.size.width, 1), height: bounds.height)
        let glyphs = lm.glyphRange(forBoundingRect: vis, in: tc)
        lm.enumerateLineFragments(forGlyphRange: glyphs) { fragRect, _, _, glyphRange, _ in
            let chars = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard chars.location == 0 || ns.character(at: chars.location - 1) == 10 else { return }
            drawNumber(tv.lineNumber(at: chars.location), y: fragRect.minY + inset.top - off.y, h: fragRect.height)
        }
        let extra = lm.extraLineFragmentRect
        if extra.height > 0 {
            let y = extra.minY + inset.top - off.y
            if y < bounds.height && y + extra.height > 0 { drawNumber(tv.lineStarts.count, y: y, h: extra.height) }
        }
    }
}

// MARK: - Text view

final class CodeTextView: UITextView {
    static let fullThreshold = 80_000

    let gutter = CodeGutterView()
    let lineHighlight = UIView()
    var lineStarts: [Int] = [0]
    var language: CodeLanguage
    var gutterWidth: CGFloat = 44
    var suppressAuto = false
    private(set) var isStyling = false
    var markers: [Int: Int] = [:]   // line -> 1 warning, 2 error
    private(set) var codeFont: UIFont
    private(set) var numberFont: UIFont
    private var highlighted = NSRange(location: 0, length: 0)
    private var syntax: CodeSyntax

    init(language: CodeLanguage, fontSize: CGFloat, accent: UIColor) {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        tc.lineFragmentPadding = 0
        lm.allowsNonContiguousLayout = true
        lm.addTextContainer(tc)
        storage.addLayoutManager(lm)

        self.language = language
        self.syntax = CodeSyntax.forLanguage(language)
        self.codeFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        self.numberFont = UIFont.monospacedDigitSystemFont(ofSize: max(8, fontSize - 2), weight: .regular)
        super.init(frame: .zero, textContainer: tc)

        backgroundColor = CodePalette.background
        textColor = CodePalette.text
        font = codeFont
        tintColor = accent
        keyboardAppearance = .dark
        keyboardDismissMode = .interactive
        alwaysBounceVertical = true
        contentInsetAdjustmentBehavior = .never
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        if #available(iOS 17.0, *) { inlinePredictionType = .no }
        gutter.tv = self
        lineHighlight.backgroundColor = CodePalette.currentLine
        lineHighlight.isUserInteractionEnabled = false
        insertSubview(lineHighlight, at: 0)
        textContainerInset = UIEdgeInsets(top: 10, left: gutterWidth + 8, bottom: 90, right: 10)
        inputAccessoryView = makeAccessory()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: loading / editing

    func load(text: String) {
        self.text = text
        rebuildLineIndex()
        gutterWidth = 0
        updateGutterMetrics()
        highlighted = NSRange(location: 0, length: 0)
    }

    func didEdit() {
        rebuildLineIndex()
        updateGutterMetrics()
        rehighlight(force: true)
        updateCurrentLineHighlight()
        resetTypingAttributes()
        gutter.setNeedsDisplay()
    }

    func replaceText(in range: NSRange, with text: String) {
        guard let s = position(from: beginningOfDocument, offset: range.location),
              let e = position(from: s, offset: range.length),
              let tr = textRange(from: s, to: e) else { return }
        suppressAuto = true
        replace(tr, withText: text)
        suppressAuto = false
    }

    func applyFontSize(_ size: CGFloat) {
        codeFont = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        numberFont = UIFont.monospacedDigitSystemFont(ofSize: max(8, size - 2), weight: .regular)
        font = codeFont
        gutterWidth = 0
        updateGutterMetrics()
        rehighlight(force: true)
        updateCurrentLineHighlight()
        gutter.setNeedsDisplay()
    }

    // MARK: line index

    func rebuildLineIndex() {
        let ns: NSString = textStorage.mutableString
        let n = ns.length
        var starts = [0]
        var buf = [unichar](repeating: 0, count: 4096)
        var i = 0
        while i < n {
            let len = min(4096, n - i)
            ns.getCharacters(&buf, range: NSRange(location: i, length: len))
            for j in 0..<len where buf[j] == 10 { starts.append(i + j + 1) }
            i += len
        }
        lineStarts = starts
    }

    func lineNumber(at loc: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= loc { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    var currentLineNumber: Int { lineNumber(at: selectedRange.location) }
    var currentColumn: Int {
        let l = currentLineNumber
        return selectedRange.location - lineStarts[l - 1] + 1
    }

    func updateGutterMetrics() {
        let digits = max(3, String(lineStarts.count).count)
        let w = ceil(CGFloat(digits) * ("0" as NSString).size(withAttributes: [.font: numberFont]).width) + 16
        if abs(w - gutterWidth) > 0.5 {
            gutterWidth = w
            textContainerInset = UIEdgeInsets(top: 10, left: w + 8, bottom: 90, right: 10)
            superview?.setNeedsLayout()
        }
    }

    func updateCurrentLineHighlight() {
        guard selectedRange.length == 0, let pos = selectedTextRange?.start else { lineHighlight.isHidden = true; return }
        let r = caretRect(for: pos)
        guard !r.isNull, !r.isInfinite, r.height > 0, r.height < 400 else { lineHighlight.isHidden = true; return }
        lineHighlight.isHidden = false
        lineHighlight.frame = CGRect(x: 0, y: r.minY - 1, width: max(contentSize.width, bounds.width), height: r.height + 2)
    }

    func scrolled() {
        gutter.setNeedsDisplay()
        if textStorage.length > Self.fullThreshold { rehighlight(force: false) }
    }

    // MARK: highlighting

    /// Attribute-only edits of the text storage (colours). Wrapped so the delegate can ignore them.
    func withAttributeEdit(_ body: (NSTextStorage) -> Void) {
        isStyling = true
        textStorage.beginEditing()
        body(textStorage)
        textStorage.endEditing()
        isStyling = false
    }

    /// New typing must not inherit a neighbour's syntax / find colour.
    func resetTypingAttributes() {
        typingAttributes = [.font: codeFont, .foregroundColor: CodePalette.text]
    }

    func visibleCharacterRange() -> NSRange {
        let total = textStorage.length
        guard bounds.height > 0, textContainer.size.width > 1 else { return NSRange(location: 0, length: min(total, 4000)) }
        let rect = CGRect(x: 0, y: contentOffset.y - textContainerInset.top, width: textContainer.size.width, height: bounds.height)
        let g = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        return layoutManager.characterRange(forGlyphRange: g, actualGlyphRange: nil)
    }

    func rehighlight(force: Bool) {
        let total = textStorage.length
        guard total > 0 else { return }
        let ns: NSString = textStorage.mutableString
        var win = NSRange(location: 0, length: total)

        if total > Self.fullThreshold {
            let vis = visibleCharacterRange()
            let needStart = max(0, vis.location - 1500), needEnd = min(total, NSMaxRange(vis) + 1500)
            if !force && highlighted.length > 0 && highlighted.location <= needStart && NSMaxRange(highlighted) >= needEnd { return }
            var start = max(0, vis.location - 5000)
            var end = min(total, NSMaxRange(vis) + 5000)
            start = ns.lineRange(for: NSRange(location: start, length: 0)).location
            end = NSMaxRange(ns.lineRange(for: NSRange(location: min(end, total - 1), length: 0)))
            if start > 0 {
                let before = NSRange(location: 0, length: start)
                let open = ns.range(of: "/*", options: .backwards, range: before)
                if open.location != NSNotFound {
                    let close = ns.range(of: "*/", options: .backwards, range: before)
                    if close.location == NSNotFound || close.location < open.location {
                        start = ns.lineRange(for: NSRange(location: open.location, length: 0)).location
                    }
                }
            }
            win = NSRange(location: start, length: max(0, end - start))
        } else if !force {
            return
        }
        highlighted = win
        guard markedTextRange == nil else { return }
        let str = textStorage.string
        withAttributeEdit { st in syntax.apply(to: st, text: str, range: win) }
    }

    // MARK: input accessory

    private func makeAccessory() -> UIView {
        let bar = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 42))
        bar.autoresizingMask = .flexibleWidth
        bar.backgroundColor = UIColor(white: 0.11, alpha: 1)
        let sv = UIScrollView(frame: bar.bounds)
        sv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sv.showsHorizontalScrollIndicator = false
        bar.addSubview(sv)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        sv.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: sv.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: sv.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: sv.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: sv.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: sv.frameLayoutGuide.heightAnchor),
        ])

        func style(_ b: UIButton) {
            b.backgroundColor = UIColor(white: 0.22, alpha: 1)
            b.layer.cornerRadius = 7
            b.setTitleColor(.white, for: .normal)
            b.tintColor = .white
            b.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 17, weight: .medium)
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
            b.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }

        let dismiss = UIButton(type: .system, primaryAction: UIAction(image: UIImage(systemName: "keyboard.chevron.compact.down")) { [weak self] _ in
            self?.resignFirstResponder()
        })
        style(dismiss)
        stack.addArrangedSubview(dismiss)

        let items: [(String, String)] = [
            ("⇥", "    "), ("{", "{"), ("}", "}"), ("(", "("), (")", ")"), ("[", "["), ("]", "]"), (";", ";"),
            ("\"", "\""), ("'", "'"), ("<", "<"), (">", ">"), ("*", "*"), ("&", "&"), ("#", "#"), ("%", "%"),
            ("@", "@"), ("!", "!"), ("=", "="), ("-", "-"), ("+", "+"), ("/", "/"), ("\\", "\\"), ("_", "_"),
            (":", ":"), (".", "."), (",", ","), ("|", "|"), ("~", "~"), ("^", "^"), ("?", "?"), ("$", "$"),
        ]
        for (title, ins) in items {
            let b = UIButton(type: .system, primaryAction: UIAction(title: title) { [weak self] _ in
                self?.insertText(ins)
            })
            style(b)
            stack.addArrangedSubview(b)
        }
        return bar
    }
}

// MARK: - Container

final class CodeEditorContainer: UIView {
    var textView: CodeTextView?
    private var lastSize: CGSize = .zero

    func install(_ tv: CodeTextView) {
        textView = tv
        backgroundColor = CodePalette.background
        addSubview(tv)
        addSubview(tv.gutter)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let tv = textView else { return }
        tv.frame = bounds
        tv.gutter.frame = CGRect(x: 0, y: 0, width: tv.gutterWidth, height: bounds.height)
        if bounds.size != lastSize {
            lastSize = bounds.size
            tv.rehighlight(force: true)
            tv.updateCurrentLineHighlight()
        }
        tv.gutter.setNeedsDisplay()
    }
}

// MARK: - Controller (find / replace / undo / state)

final class CodeEditorController: ObservableObject {
    private static let sizeKey = "dtx.editor.fontSize"

    weak var textView: CodeTextView?

    @Published var canUndo = false
    @Published var canRedo = false
    @Published var line = 1
    @Published var column = 1
    @Published var lineCount = 1

    @Published var query = ""
    @Published var caseSensitive = false
    @Published var useRegex = false
    @Published var matchCount = 0
    @Published var matchIndex = 0
    @Published var regexInvalid = false

    @Published var fontSize: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "dtx.editor.fontSize") as? Double ?? 13) {
        didSet {
            UserDefaults.standard.set(Double(fontSize), forKey: Self.sizeKey)
            textView?.applyFontSize(fontSize)
        }
    }

    var findActive = false
    private var matches: [NSRange] = []
    private var current = -1
    private var regex: NSRegularExpression?

    func attach(_ tv: CodeTextView) { textView = tv }

    func text() -> String { textView?.textStorage.string ?? "" }

    func refreshState() {
        guard let tv = textView else { return }
        canUndo = tv.undoManager?.canUndo ?? false
        canRedo = tv.undoManager?.canRedo ?? false
        line = tv.currentLineNumber
        column = tv.currentColumn
        lineCount = tv.lineStarts.count
    }

    func textChanged() {
        refreshState()
        if findActive && !query.isEmpty { updateFind() }
    }

    func focus() { _ = textView?.becomeFirstResponder() }

    // undo / redo
    func undo() { textView?.undoManager?.undo(); textView?.didEdit(); refreshState() }
    func redo() { textView?.undoManager?.redo(); textView?.didEdit(); refreshState() }

    // go to line
    func goTo(line n: Int) {
        guard let tv = textView else { return }
        let l = min(max(1, n), tv.lineStarts.count)
        let loc = tv.lineStarts[l - 1]
        tv.selectedRange = NSRange(location: loc, length: 0)
        reveal(NSRange(location: loc, length: 0))
        _ = tv.becomeFirstResponder()
        refreshState()
    }

    func setMarkers(_ m: [Int: Int]) {
        textView?.markers = m
        textView?.gutter.setNeedsDisplay()
    }

    /// Replaces the whole document as ONE undoable edit (used by diff revert).
    func replaceAllText(_ s: String) {
        guard let tv = textView else { return }
        let full = NSRange(location: 0, length: tv.textStorage.length)
        let caret = min(tv.selectedRange.location, (s as NSString).length)
        tv.replaceText(in: full, with: s)
        tv.selectedRange = NSRange(location: caret, length: 0)
        tv.didEdit()
        textChanged()
    }

    /// Moves the caret to a recovered function: tries the full label, then the selector, then its first keyword.
    func jump(toSymbol label: String) {
        guard let tv = textView else { return }
        let ns: NSString = tv.textStorage.mutableString
        var cands = [label]
        if label.hasPrefix("-[") || label.hasPrefix("+[") {
            let inner = String(label.dropFirst(2).dropLast())
            let parts = inner.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                cands.append(parts[1])
                if let first = parts[1].split(separator: ":").first { cands.append(String(first)) }
            }
        } else {
            cands.append(label.replacingOccurrences(of: "()", with: ""))
        }
        for c in cands where !c.isEmpty {
            let r = ns.range(of: c)
            if r.location != NSNotFound {
                tv.selectedRange = NSRange(location: r.location, length: 0)
                reveal(r)
                refreshState()
                return
            }
        }
    }

    func selectionInfo() -> (text: String, line: Int)? {
        guard let tv = textView, tv.selectedRange.length > 0 else { return nil }
        let ns: NSString = tv.textStorage.mutableString
        return (ns.substring(with: tv.selectedRange), tv.lineNumber(at: tv.selectedRange.location))
    }

    func prefillFromSelection() {
        guard let tv = textView else { return }
        let r = tv.selectedRange
        if r.length > 0 && r.length < 120 {
            let s = (tv.textStorage.mutableString as NSString).substring(with: r)
            if !s.contains("\n") { query = s }
        }
    }

    // MARK: find

    func updateFind() {
        guard let tv = textView else { return }
        matches = []
        regexInvalid = false
        regex = nil
        let total = tv.textStorage.length
        let full = NSRange(location: 0, length: total)
        tv.withAttributeEdit { $0.removeAttribute(.backgroundColor, range: full) }
        guard findActive, !query.isEmpty, total > 0 else {
            matchCount = 0; matchIndex = 0; current = -1
            return
        }
        let s = tv.textStorage.string
        if useRegex {
            var opts: NSRegularExpression.Options = [.anchorsMatchLines]
            if !caseSensitive { opts.insert(.caseInsensitive) }
            guard let re = try? NSRegularExpression(pattern: query, options: opts) else {
                regexInvalid = true; matchCount = 0; matchIndex = 0; current = -1
                return
            }
            regex = re
            var found: [NSRange] = []
            re.enumerateMatches(in: s, options: [], range: full) { m, _, stop in
                guard let m = m, m.range.length > 0 else { return }
                found.append(m.range)
                if found.count >= 20000 { stop.pointee = true }
            }
            matches = found
        } else {
            let ns: NSString = tv.textStorage.mutableString
            let opts: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            var r = NSRange(location: 0, length: ns.length)
            var found: [NSRange] = []
            while r.length > 0 {
                let f = ns.range(of: query, options: opts, range: r)
                if f.location == NSNotFound || f.length == 0 { break }
                found.append(f)
                if found.count >= 20000 { break }
                let next = NSMaxRange(f)
                r = NSRange(location: next, length: ns.length - next)
            }
            matches = found
        }
        let sel = tv.selectedRange.location
        current = matches.firstIndex { $0.location >= sel } ?? (matches.isEmpty ? -1 : 0)
        paint()
    }

    private func paint() {
        guard let tv = textView else { return }
        let full = NSRange(location: 0, length: tv.textStorage.length)
        let shown = matches.prefix(5000)
        let cur = (current >= 0 && current < matches.count) ? matches[current] : nil
        tv.withAttributeEdit { st in
            st.removeAttribute(.backgroundColor, range: full)
            for m in shown where NSMaxRange(m) <= full.length { st.addAttribute(.backgroundColor, value: CodePalette.findMatch, range: m) }
            if let c = cur, NSMaxRange(c) <= full.length { st.addAttribute(.backgroundColor, value: CodePalette.findCurrent, range: c) }
        }
        matchCount = matches.count
        matchIndex = cur != nil ? current + 1 : 0
    }

    func next() { step(1) }
    func prev() { step(-1) }

    private func step(_ d: Int) {
        guard !matches.isEmpty else { return }
        if current < 0 { current = 0 } else { current = (current + d + matches.count) % matches.count }
        paint()
        reveal(matches[current])
    }

    func reveal(_ r: NSRange) {
        guard let tv = textView else { return }
        let lm = tv.layoutManager
        let g = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: g, in: tv.textContainer)
        let target = rect.midY + tv.textContainerInset.top - tv.bounds.height / 2
        let maxY = max(0, tv.contentSize.height - tv.bounds.height)
        tv.setContentOffset(CGPoint(x: 0, y: min(max(0, target), maxY)), animated: true)
    }

    // MARK: replace

    func replaceCurrent(with template: String) {
        guard let tv = textView, current >= 0, current < matches.count else { return }
        let r = matches[current]
        var rep = template
        if useRegex, let re = regex {
            let s = tv.textStorage.string
            if let m = re.firstMatch(in: s, options: [.anchored], range: r) {
                rep = re.replacementString(for: m, in: s, offset: 0, template: template)
            }
        }
        tv.replaceText(in: r, with: rep)
        tv.selectedRange = NSRange(location: r.location + (rep as NSString).length, length: 0)
        tv.didEdit()
        updateFind()
        refreshState()
        if current >= 0 && current < matches.count { reveal(matches[current]) }
    }

    func replaceAll(with template: String) {
        guard let tv = textView, !matches.isEmpty else { return }
        let s = tv.textStorage.string
        let full = NSRange(location: 0, length: (s as NSString).length)
        let result: String
        if useRegex, let re = regex {
            result = re.stringByReplacingMatches(in: s, options: [], range: full, withTemplate: template)
        } else {
            let ms = NSMutableString(string: s)
            ms.replaceOccurrences(of: query, with: template, options: caseSensitive ? [] : [.caseInsensitive], range: full)
            result = ms as String
        }
        let caret = min(tv.selectedRange.location, (result as NSString).length)
        tv.replaceText(in: full, with: result)
        tv.selectedRange = NSRange(location: caret, length: 0)
        tv.didEdit()
        updateFind()
        refreshState()
    }
}

// MARK: - SwiftUI wrapper

struct CodeEditorView: UIViewRepresentable {
    let initialText: String
    let language: CodeLanguage
    let controller: CodeEditorController
    var onEdit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEdit: onEdit, controller: controller) }

    func makeUIView(context: Context) -> CodeEditorContainer {
        let container = CodeEditorContainer()
        let tv = CodeTextView(language: language, fontSize: controller.fontSize, accent: UIColor(Color.dtAccent))
        tv.load(text: initialText)
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        container.install(tv)
        controller.attach(tv)
        DispatchQueue.main.async {
            controller.refreshState()
            tv.rehighlight(force: true)
        }
        return container
    }

    func updateUIView(_ uiView: CodeEditorContainer, context: Context) {
        context.coordinator.onEdit = onEdit
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onEdit: () -> Void
        let controller: CodeEditorController
        weak var textView: CodeTextView?

        init(onEdit: @escaping () -> Void, controller: CodeEditorController) {
            self.onEdit = onEdit
            self.controller = controller
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let t = self.textView, !t.isStyling else { return }
            t.didEdit()
            controller.textChanged()
            onEdit()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard let t = self.textView, !t.isStyling else { return }
            t.resetTypingAttributes()
            t.updateCurrentLineHighlight()
            t.gutter.setNeedsDisplay()
            controller.refreshState()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            textView?.scrolled()
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", let t = self.textView, !t.suppressAuto, t.markedTextRange == nil, t.language.autoIndent else { return true }
            let ns: NSString = t.textStorage.mutableString
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            var indent = ""
            var i = lineRange.location
            while i < range.location {
                let c = ns.character(at: i)
                if c == 32 || c == 9, let u = Unicode.Scalar(c) { indent.append(Character(u)); i += 1 } else { break }
            }
            let prev: unichar = range.location > 0 ? ns.character(at: range.location - 1) : 0
            let after = range.location + range.length
            let next: unichar = after < ns.length ? ns.character(at: after) : 0
            var insert = "\n" + indent
            var caretOffset = (insert as NSString).length
            if prev == 123 { // {
                insert += "    "
                caretOffset = (insert as NSString).length
                if next == 125 { insert += "\n" + indent } // }
            }
            t.replaceText(in: range, with: insert)
            t.selectedRange = NSRange(location: range.location + caretOffset, length: 0)
            textViewDidChange(t)
            return false
        }
    }
}
