import AppKit
import SwiftUI

private let editorTextInset = NSSize(width: 6, height: 16)

struct TextEditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    var fileName: String = ""
    var jumpRequest: EditorJumpRequest?
    var onTextChange: (String) -> Void
    var onCursorChange: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = AppTheme.editorBackgroundColor
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.hasVerticalRuler = true

        let textView = ThemedTextView()
        textView.onAppearanceChange = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return }
            DispatchQueue.main.async {
                guard let textView = coordinator.textView, let scrollView = textView.enclosingScrollView else { return }
                coordinator.applyAppearanceAndHighlighting(in: scrollView)
            }
        }
        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = SyntaxHighlighter.baseColor(for: textView.effectiveAppearance)
        textView.insertionPointColor = .controlAccentColor
        textView.selectedTextAttributes = selectedTextAttributes(for: textView)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.rulersVisible = true
        scrollView.tile()
        applyEditorAppearance(textView, in: scrollView)
        configureTextLayout(textView, in: scrollView)

        context.coordinator.textView = textView
        context.coordinator.rulerView = ruler
        context.coordinator.scheduleFullHighlighting()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        let previousFileName = context.coordinator.parent.fileName
        context.coordinator.parent = self
        context.coordinator.applyAppearanceIfNeeded(in: scrollView)
        if textView.string != text {
            textView.string = text
            context.coordinator.invalidateCursorLineStarts()
            configureTextLayout(textView, in: scrollView)
            context.coordinator.scheduleFullHighlighting()
            context.coordinator.rulerView?.needsDisplay = true
        } else if previousFileName != fileName {
            configureTextLayout(textView, in: scrollView)
            context.coordinator.scheduleFullHighlighting()
            context.coordinator.rulerView?.needsDisplay = true
        }
        context.coordinator.applyJumpIfNeeded(in: scrollView)
    }

    private func selectedTextAttributes(for textView: NSTextView) -> [NSAttributedString.Key: Any] {
        [
            .backgroundColor: AppTheme.editorSelectionColor,
            .foregroundColor: SyntaxHighlighter.baseColor(for: textView.effectiveAppearance)
        ]
    }

    private func applyEditorAppearance(_ textView: NSTextView, in scrollView: NSScrollView) {
        scrollView.backgroundColor = AppTheme.editorBackgroundColor
        textView.textColor = SyntaxHighlighter.baseColor(for: textView.effectiveAppearance)
        textView.selectedTextAttributes = selectedTextAttributes(for: textView)
        textView.insertionPointColor = .controlAccentColor
    }

    private func configureTextLayout(_ textView: NSTextView, in scrollView: NSScrollView) {
        let visibleWidth = max(1, scrollView.contentSize.width)
        textView.textContainerInset = editorTextInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: visibleWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.frame.size.width = visibleWidth
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextEditorRepresentable
        weak var textView: NSTextView?
        weak var rulerView: LineNumberRulerView?
        private var isApplyingHighlighting = false
        private var pendingHighlightTask: Task<Void, Never>?
        private var appliedAppearanceKey: String?
        private var appliedJumpID: UUID?
        private var cursorLineStarts: [Int] = []
        private var cursorLineStartsTextLength = -1

        init(parent: TextEditorRepresentable) {
            self.parent = parent
        }

        deinit {
            pendingHighlightTask?.cancel()
        }

        func scheduleFullHighlighting() {
            guard let textView else { return }
            pendingHighlightTask?.cancel()
            let textLength = textView.string.utf16.count
            let delay: UInt64 = textLength > 200_000 ? 180_000_000 : 16_000_000
            pendingHighlightTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard let self, !Task.isCancelled else { return }
                self.applyHighlighting()
            }
        }

        func applyHighlighting(editedRange: NSRange? = nil, changeInLength: Int = 0) {
            guard let textView, !isApplyingHighlighting else { return }
            if editedRange != nil {
                pendingHighlightTask?.cancel()
            }
            isApplyingHighlighting = true
            defer { isApplyingHighlighting = false }
            if let editedRange {
                SyntaxHighlighter.applyIncremental(to: textView, fileName: parent.fileName, editedRange: editedRange, changeInLength: changeInLength)
            } else {
                SyntaxHighlighter.apply(to: textView, fileName: parent.fileName)
            }
        }

        func applyAppearanceIfNeeded(in scrollView: NSScrollView) {
            guard let textView else { return }
            let key = appearanceKey(for: textView)
            guard appliedAppearanceKey != key else { return }
            applyAppearanceAndHighlighting(in: scrollView)
        }

        func applyAppearanceAndHighlighting(in scrollView: NSScrollView) {
            guard let textView else { return }
            appliedAppearanceKey = appearanceKey(for: textView)
            parent.applyEditorAppearance(textView, in: scrollView)
            scheduleFullHighlighting()
            rulerView?.needsDisplay = true
        }

        private func appearanceKey(for textView: NSTextView) -> String {
            textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            let editedRange = textView.textStorage?.editedRange
            let changeInLength = textView.textStorage?.changeInLength ?? 0
            if let scrollView = textView.enclosingScrollView {
                parent.configureTextLayout(textView, in: scrollView)
            }
            applyHighlighting(editedRange: editedRange, changeInLength: changeInLength)
            invalidateCursorLineStarts()
            let newText = textView.string
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                parent.text = newText
                parent.onTextChange(newText)
                rulerView?.needsDisplay = true
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let location = textView.selectedRange().location
            let nsString = textView.string as NSString
            let position = cursorPosition(for: location, in: nsString)
            DispatchQueue.main.async { [weak self] in
                self?.parent.onCursorChange(position.line, position.column)
            }
        }

        func invalidateCursorLineStarts() {
            cursorLineStartsTextLength = -1
            cursorLineStarts.removeAll(keepingCapacity: true)
        }

        private func cursorPosition(for location: Int, in text: NSString) -> (line: Int, column: Int) {
            let boundedLocation = min(max(0, location == NSNotFound ? 0 : location), text.length)
            ensureCursorLineStarts(for: text)
            var lo = 0
            var hi = max(0, cursorLineStarts.count - 1)
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if cursorLineStarts[mid] <= boundedLocation {
                    lo = mid
                } else {
                    hi = mid - 1
                }
            }
            return (lo + 1, boundedLocation - cursorLineStarts[lo] + 1)
        }

        private func ensureCursorLineStarts(for text: NSString) {
            guard cursorLineStartsTextLength != text.length || cursorLineStarts.isEmpty else { return }
            var starts = [0]
            starts.reserveCapacity(max(text.length / 40, 16))
            var index = 0
            while index < text.length {
                if text.character(at: index) == 10 {
                    starts.append(index + 1)
                }
                index += 1
            }
            cursorLineStarts = starts
            cursorLineStartsTextLength = text.length
        }

        func applyJumpIfNeeded(in scrollView: NSScrollView) {
            guard let request = parent.jumpRequest, appliedJumpID != request.id, let textView else { return }
            appliedJumpID = request.id
            let nsString = textView.string as NSString
            let targetLocation = characterLocation(in: nsString, line: request.line, column: request.column)
            let range = NSRange(location: targetLocation, length: 0)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            scrollView.window?.makeFirstResponder(textView)
            parent.onCursorChange(request.line, request.column)
        }

        private func characterLocation(in text: NSString, line: Int, column: Int) -> Int {
            let line = max(1, line)
            let column = max(1, column)
            var currentLine = 1
            var location = 0
            while currentLine < line && location < text.length {
                let range = text.range(of: "\n", options: [], range: NSRange(location: location, length: text.length - location))
                guard range.location != NSNotFound else { return text.length }
                location = range.location + range.length
                currentLine += 1
            }
            return min(text.length, location + column - 1)
        }
    }
}

private final class ThemedTextView: NSTextView {
    var onAppearanceChange: () -> Void = {}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange()
    }
}

private struct SyntaxColorPalette {
    let base: NSColor
    let keyword: NSColor
    let string: NSColor
    let comment: NSColor
    let type: NSColor
    let number: NSColor
    let function: NSColor
    let attribute: NSColor
    let key: NSColor

    init(appearance: NSAppearance) {
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            base = NSColor(calibratedRed: 0.86, green: 0.88, blue: 0.91, alpha: 1)
            keyword = NSColor(calibratedRed: 0.52, green: 0.66, blue: 1.00, alpha: 1)
            string = NSColor(calibratedRed: 0.43, green: 0.82, blue: 0.54, alpha: 1)
            comment = NSColor(calibratedRed: 0.48, green: 0.53, blue: 0.60, alpha: 1)
            type = NSColor(calibratedRed: 0.76, green: 0.58, blue: 1.00, alpha: 1)
            number = NSColor(calibratedRed: 1.00, green: 0.67, blue: 0.38, alpha: 1)
            function = NSColor(calibratedRed: 0.40, green: 0.82, blue: 0.78, alpha: 1)
            attribute = NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.36, alpha: 1)
            key = NSColor(calibratedRed: 0.46, green: 0.82, blue: 0.92, alpha: 1)
        } else {
            base = NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.20, alpha: 1)
            keyword = NSColor(calibratedRed: 0.11, green: 0.31, blue: 0.85, alpha: 1)
            string = NSColor(calibratedRed: 0.08, green: 0.50, blue: 0.24, alpha: 1)
            comment = NSColor(calibratedRed: 0.42, green: 0.45, blue: 0.50, alpha: 1)
            type = NSColor(calibratedRed: 0.49, green: 0.23, blue: 0.93, alpha: 1)
            number = NSColor(calibratedRed: 0.71, green: 0.33, blue: 0.04, alpha: 1)
            function = NSColor(calibratedRed: 0.05, green: 0.46, blue: 0.44, alpha: 1)
            attribute = NSColor(calibratedRed: 0.76, green: 0.25, blue: 0.05, alpha: 1)
            key = NSColor(calibratedRed: 0.04, green: 0.45, blue: 0.55, alpha: 1)
        }
    }
}

private enum SyntaxHighlighter {
    static func baseColor(for appearance: NSAppearance) -> NSColor {
        SyntaxColorPalette(appearance: appearance).base
    }

    static func apply(to textView: NSTextView, fileName: String) {
        guard let storage = textView.textStorage else { return }
        let text = storage.string as NSString
        let fullRange = NSRange(location: 0, length: text.length)
        let selectedRange = textView.selectedRange()
        let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .light)
        let italicFont = Self.italicVariant(of: font)
        let palette = SyntaxColorPalette(appearance: textView.effectiveAppearance)

        storage.beginEditing()
        storage.setAttributes([
            .font: font,
            .foregroundColor: palette.base
        ], range: fullRange)

        guard fullRange.length > 0 else {
            storage.endEditing()
            return
        }

        let language = SyntaxLanguage(fileName: fileName)
        let stringRanges = ranges(pattern: stringPattern(for: language), storage: storage, range: fullRange)
        let commentRanges = ranges(pattern: commentPattern(for: language), storage: storage, range: fullRange)
            .filter { !intersects($0, stringRanges) }
        applyHighlightRules(language: language, palette: palette, storage: storage, range: fullRange, stringRanges: stringRanges, commentRanges: commentRanges, italicFont: italicFont)

        storage.endEditing()
        restoreSelection(selectedRange, in: textView, textLength: text.length)
    }

    static func applyIncremental(to textView: NSTextView, fileName: String, editedRange: NSRange, changeInLength: Int) {
        guard let storage = textView.textStorage else { return }
        let text = storage.string as NSString
        guard text.length > 0, let normalizedRange = normalizedRange(editedRange, textLength: text.length), let targetRange = expandedLineRange(for: normalizedRange, in: text), targetRange.length > 0 else {
            apply(to: textView, fileName: fileName)
            return
        }
        guard !shouldUseFullRebuild(text: text, editedRange: normalizedRange, targetRange: targetRange, changeInLength: changeInLength) else {
            apply(to: textView, fileName: fileName)
            return
        }

        let selectedRange = textView.selectedRange()
        let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .light)
        let italicFont = Self.italicVariant(of: font)
        let language = SyntaxLanguage(fileName: fileName)
        let palette = SyntaxColorPalette(appearance: textView.effectiveAppearance)

        storage.beginEditing()
        storage.setAttributes([
            .font: font,
            .foregroundColor: palette.base
        ], range: targetRange)

        let stringRanges = ranges(pattern: stringPattern(for: language), storage: storage, range: targetRange)
        let commentRanges = ranges(pattern: commentPattern(for: language), storage: storage, range: targetRange)
            .filter { !intersects($0, stringRanges) }
        applyHighlightRules(language: language, palette: palette, storage: storage, range: targetRange, stringRanges: stringRanges, commentRanges: commentRanges, italicFont: italicFont)

        storage.endEditing()
        restoreSelection(selectedRange, in: textView, textLength: text.length)
    }

    private static func applyHighlightRules(language: SyntaxLanguage, palette: SyntaxColorPalette, storage: NSTextStorage, range: NSRange, stringRanges: [NSRange], commentRanges: [NSRange], italicFont: NSFont) {
        let protectedRanges = stringRanges + commentRanges

        if language == .markdown {
            apply(pattern: #"(?m)^\s{0,3}#{1,6}\s+.+$"#, attributes: [.foregroundColor: palette.keyword], storage: storage, range: range)
            apply(pattern: #"(?m)^\s*(?:[-*+]|\d+\.)\s+"#, attributes: [.foregroundColor: palette.attribute], storage: storage, range: range)
            apply(pattern: #"\[[^\]\n]+\]\([^\)\n]+\)"#, attributes: [.foregroundColor: palette.key], storage: storage, range: range)
        }

        if language == .json || language == .yaml {
            apply(pattern: #"(?m)(^|[,\{]\s*)(\"?[A-Za-z_][A-Za-z0-9_ .-]*\"?)(\s*:)"#, captureGroup: 2, attributes: [.foregroundColor: palette.key], storage: storage, range: range, excluding: protectedRanges)
            apply(pattern: #"(?m)^\s*([A-Za-z_][A-Za-z0-9_ .-]*)(?=\s*:)"#, captureGroup: 1, attributes: [.foregroundColor: palette.key], storage: storage, range: range, excluding: protectedRanges)
        }

        apply(pattern: keywordPattern(for: language), attributes: [.foregroundColor: palette.keyword], storage: storage, range: range, excluding: protectedRanges)
        apply(pattern: #"\b([A-Z][A-Za-z0-9_]*|String|Int|Double|Float|Bool|Array|Dictionary|Set|URL|UUID|Date|Data|View|Color|Text|Button|Image|Result|Task|DateFormatter|URLRequest|JSONDecoder|JSONEncoder)\b"#, attributes: [.foregroundColor: palette.type], storage: storage, range: range, excluding: protectedRanges)
        apply(pattern: #"\b(?:0x[0-9A-Fa-f_]+|\d[\d_]*(?:\.\d[\d_]*)?)(?:[eE][+-]?\d+)?\b"#, attributes: [.foregroundColor: palette.number], storage: storage, range: range, excluding: protectedRanges)
        apply(pattern: #"\b(?:func|function|def|fn)\s+([A-Za-z_][A-Za-z0-9_]*)"#, captureGroup: 1, attributes: [.foregroundColor: palette.function], storage: storage, range: range, excluding: protectedRanges)
        apply(pattern: #"\b(?!if\b|for\b|while\b|switch\b|catch\b|guard\b|return\b|func\b|function\b|def\b|fn\b|try\b|await\b)([a-z_][A-Za-z0-9_]*)\s*(?=\()"#, captureGroup: 1, attributes: [.foregroundColor: palette.function], storage: storage, range: range, excluding: protectedRanges)
        apply(pattern: #"@[A-Za-z_][A-Za-z0-9_]*|#(?:if|else|elseif|endif|available|selector|keyPath|file|line|warning|error)\b"#, attributes: [.foregroundColor: palette.attribute], storage: storage, range: range, excluding: stringRanges)
        apply(ranges: stringRanges, attributes: [.foregroundColor: palette.string], storage: storage)
        apply(ranges: commentRanges, attributes: [.foregroundColor: palette.comment, .font: italicFont], storage: storage)
    }

    private static func restoreSelection(_ selectedRange: NSRange, in textView: NSTextView, textLength: Int) {
        let location = min(selectedRange.location, textLength)
        let length = min(selectedRange.length, max(0, textLength - location))
        textView.setSelectedRange(NSRange(location: location, length: length))
    }

    private static func normalizedRange(_ range: NSRange, textLength: Int) -> NSRange? {
        guard range.location != NSNotFound, range.location >= 0, range.location <= textLength else { return nil }
        return NSRange(location: range.location, length: min(max(0, range.length), textLength - range.location))
    }

    private static func expandedLineRange(for range: NSRange, in text: NSString) -> NSRange? {
        guard let baseRange = normalizedRange(range, textLength: text.length) else { return nil }
        var expanded = text.lineRange(for: baseRange)
        if expanded.location > 0 {
            expanded = NSUnionRange(text.lineRange(for: NSRange(location: expanded.location - 1, length: 0)), expanded)
        }
        let nextLocation = NSMaxRange(expanded)
        if nextLocation < text.length {
            expanded = NSUnionRange(expanded, text.lineRange(for: NSRange(location: nextLocation, length: 0)))
        }
        return normalizedRange(expanded, textLength: text.length)
    }

    private static func shouldUseFullRebuild(text: NSString, editedRange: NSRange, targetRange: NSRange, changeInLength: Int) -> Bool {
        if max(abs(changeInLength), editedRange.length) > 256 { return true }
        let contextRange = surroundingRange(for: targetRange, textLength: text.length, padding: 256)
        if containsMultilineDelimiter(in: text, range: contextRange) { return true }
        let start = targetRange.location
        let end = min(text.length, NSMaxRange(targetRange))
        return isInsideDelimitedRegion(text, startDelimiter: "/*", endDelimiter: "*/", location: start)
            || isInsideDelimitedRegion(text, startDelimiter: "/*", endDelimiter: "*/", location: end)
            || isInsideTripleQuotedRegion(text, location: start)
            || isInsideTripleQuotedRegion(text, location: end)
    }

    private static func surroundingRange(for range: NSRange, textLength: Int, padding: Int) -> NSRange {
        let lowerBound = max(0, range.location - padding)
        let upperBound = min(textLength, NSMaxRange(range) + padding)
        return NSRange(location: lowerBound, length: max(0, upperBound - lowerBound))
    }

    private static func containsMultilineDelimiter(in text: NSString, range: NSRange) -> Bool {
        text.range(of: "\"\"\"", options: [], range: range).location != NSNotFound
            || text.range(of: "/*", options: [], range: range).location != NSNotFound
            || text.range(of: "*/", options: [], range: range).location != NSNotFound
    }

    private static func isInsideDelimitedRegion(_ text: NSString, startDelimiter: String, endDelimiter: String, location: Int) -> Bool {
        let boundedLocation = min(max(0, location), text.length)
        guard boundedLocation > 0 else { return false }
        let beforeRange = NSRange(location: 0, length: boundedLocation)
        let lastStart = text.range(of: startDelimiter, options: .backwards, range: beforeRange).location
        guard lastStart != NSNotFound else { return false }
        let lastEnd = text.range(of: endDelimiter, options: .backwards, range: beforeRange).location
        return lastEnd == NSNotFound || lastStart > lastEnd
    }

    private static func isInsideTripleQuotedRegion(_ text: NSString, location: Int) -> Bool {
        let boundedLocation = min(max(0, location), text.length)
        guard boundedLocation > 0 else { return false }
        var count = 0
        var searchLocation = 0
        while searchLocation < boundedLocation {
            let range = NSRange(location: searchLocation, length: boundedLocation - searchLocation)
            let match = text.range(of: "\"\"\"", options: [], range: range)
            guard match.location != NSNotFound else { break }
            count += 1
            searchLocation = match.location + match.length
        }
        return count % 2 == 1
    }

    private static func apply(pattern: String, captureGroup: Int = 0, attributes: [NSAttributedString.Key: Any], storage: NSTextStorage, range: NSRange, excluding excludedRanges: [NSRange] = []) {
        guard let regex = cachedRegex(for: pattern) else { return }
        regex.enumerateMatches(in: storage.string, options: [], range: range) { match, _, _ in
            guard let match, captureGroup < match.numberOfRanges else { return }
            let matchRange = match.range(at: captureGroup)
            guard matchRange.location != NSNotFound, !intersects(matchRange, excludedRanges) else { return }
            storage.addAttributes(attributes, range: matchRange)
        }
    }

    private static func apply(ranges: [NSRange], attributes: [NSAttributedString.Key: Any], storage: NSTextStorage) {
        ranges.forEach { storage.addAttributes(attributes, range: $0) }
    }

    private static func ranges(pattern: String, storage: NSTextStorage, range: NSRange) -> [NSRange] {
        guard !pattern.isEmpty, let regex = cachedRegex(for: pattern) else { return [] }
        var result: [NSRange] = []
        regex.enumerateMatches(in: storage.string, options: [], range: range) { match, _, _ in
            guard let matchRange = match?.range else { return }
            result.append(matchRange)
        }
        return result
    }

    // MARK: - Caches

    private static let regexCache: NSCache<NSString, RegexBox> = {
        let cache = NSCache<NSString, RegexBox>()
        cache.countLimit = 64
        return cache
    }()

    private static let italicFontLock = NSLock()
    private static var italicFontCache: [String: NSFont] = [:]

    private static func cachedRegex(for pattern: String) -> NSRegularExpression? {
        guard !pattern.isEmpty else { return nil }
        let key = pattern as NSString
        if let cached = regexCache.object(forKey: key) {
            return cached.value
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        regexCache.setObject(RegexBox(regex), forKey: key)
        return regex
    }

    static func italicVariant(of font: NSFont) -> NSFont {
        let key = "\(font.fontName)|\(font.pointSize)"
        italicFontLock.lock()
        defer { italicFontLock.unlock() }
        if let cached = italicFontCache[key] {
            return cached
        }
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        italicFontCache[key] = italic
        return italic
    }

    private final class RegexBox {
        let value: NSRegularExpression
        init(_ value: NSRegularExpression) { self.value = value }
    }

    private static func intersects(_ range: NSRange, _ ranges: [NSRange]) -> Bool {
        ranges.contains { NSIntersectionRange(range, $0).length > 0 }
    }

    private static func stringPattern(for language: SyntaxLanguage) -> String {
        if language == .markdown { return #"`[^`\n]+`"# }
        return ###"("""[\s\S]*?"""|#{0,3}"(?:\\.|[^"\\])*"#{0,3}|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)"###
    }

    private static func commentPattern(for language: SyntaxLanguage) -> String {
        switch language {
        case .json, .markdown, .plain:
            return ""
        case .python, .shell, .yaml:
            return #"#[^\n]*"#
        default:
            return #"//[^\n]*|/\*[\s\S]*?\*/"#
        }
    }

    private static func keywordPattern(for language: SyntaxLanguage) -> String {
        switch language {
        case .json, .yaml:
            return #"\b(true|false|null|yes|no|on|off)\b"#
        case .markdown, .plain:
            return #"\b(TODO|FIXME|NOTE|IMPORTANT)\b"#
        default:
            return #"\b(import|from|export|package|struct|class|enum|protocol|extension|func|function|def|fn|var|let|const|if|else|elif|guard|return|switch|case|default|for|while|do|try|catch|throw|throws|async|await|private|public|internal|static|final|weak|self|this|super|nil|null|true|false|in|where|as|is|new|interface|type|defer|select|go|range|yield|actor|mutating|nonmutating)\b"#
        }
    }
}

private enum SyntaxLanguage: Equatable {
    case swiftLike
    case javaScript
    case python
    case go
    case json
    case yaml
    case markdown
    case shell
    case plain

    init(fileName: String) {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "swift", "m", "mm", "h", "java", "kt", "kts", "rs", "cpp", "cc", "cxx", "c", "hpp":
            self = .swiftLike
        case "js", "jsx", "ts", "tsx", "vue", "svelte":
            self = .javaScript
        case "py":
            self = .python
        case "go":
            self = .go
        case "json", "jsonl":
            self = .json
        case "yml", "yaml", "toml":
            self = .yaml
        case "md", "markdown", "mdx":
            self = .markdown
        case "sh", "bash", "zsh", "fish":
            self = .shell
        default:
            self = .plain
        }
    }
}
