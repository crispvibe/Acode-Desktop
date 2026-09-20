import AppKit

final class LineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?
    override var isOpaque: Bool { true }

    private var backgroundColor: NSColor { AppTheme.editorGutterBackgroundColor }
    private var attributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: AppTheme.editorSecondaryTextColor
        ]
    }

    private var lineStarts: [Int] = [0]
    private var lineStartsValid = false
    private var observedTextStorage: NSTextStorage?
    private weak var observedClipView: NSClipView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 68
        attachToTextStorage(textView.textStorage)
        attachToScrollView(textView.enclosingScrollView)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        if let storage = observedTextStorage {
            NotificationCenter.default.removeObserver(self, name: NSTextStorage.didProcessEditingNotification, object: storage)
        }
        if let clipView = observedClipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clipView)
        }
    }

    private func attachToScrollView(_ scrollView: NSScrollView?) {
        guard let clipView = scrollView?.contentView, observedClipView !== clipView else { return }
        if let previous = observedClipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: previous)
        }
        observedClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleClipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    private func attachToTextStorage(_ storage: NSTextStorage?) {
        guard let storage, observedTextStorage !== storage else { return }
        if let previous = observedTextStorage {
            NotificationCenter.default.removeObserver(self, name: NSTextStorage.didProcessEditingNotification, object: previous)
        }
        observedTextStorage = storage
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTextStorageDidProcessEditing(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: storage
        )
        invalidateLineStarts()
    }

    func invalidateLineStarts() {
        lineStarts = [0]
        lineStartsValid = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    @objc private func handleClipViewBoundsDidChange(_ note: Notification) {
        guard observedClipView === note.object as? NSClipView else { return }
        needsDisplay = true
    }

    @objc private func handleTextStorageDidProcessEditing(_ note: Notification) {
        guard let storage = note.object as? NSTextStorage else { return }
        if observedTextStorage !== storage { return }
        guard storage.editedMask.contains(.editedCharacters) else { return }
        let editedRange = storage.editedRange
        let delta = storage.changeInLength
        if !lineStartsValid {
            invalidateLineStarts()
            needsDisplay = true
            return
        }
        applyEdit(editedRange: editedRange, delta: delta, in: storage)
        needsDisplay = true
    }

    private func applyEdit(editedRange: NSRange, delta: Int, in storage: NSTextStorage) {
        guard editedRange.location != NSNotFound else {
            invalidateLineStarts()
            return
        }
        let oldLength = editedRange.length - delta
        guard oldLength >= 0 else {
            invalidateLineStarts()
            return
        }
        let editLoc = editedRange.location
        let oldEditEnd = editLoc + oldLength

        // 二分找第一个 > editLoc 的 lineStart 位置
        var lo = 0
        var hi = lineStarts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lineStarts[mid] <= editLoc {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        let firstAffected = lo

        // 删除完全位于 [editLoc, oldEditEnd) 的旧 lineStarts
        while firstAffected < lineStarts.count && lineStarts[firstAffected] < oldEditEnd {
            lineStarts.remove(at: firstAffected)
        }
        // 平移其后的 lineStarts
        if delta != 0 && firstAffected < lineStarts.count {
            for i in firstAffected..<lineStarts.count {
                lineStarts[i] += delta
            }
        }
        // 重新扫描 editedRange 内（新坐标）的换行符并插入
        let text = storage.string as NSString
        let newEditEnd = editLoc + editedRange.length
        var i = editLoc
        var insertPos = firstAffected
        while i < newEditEnd && i < text.length {
            if text.character(at: i) == 10 {
                let start = i + 1
                lineStarts.insert(start, at: insertPos)
                insertPos += 1
            }
            i += 1
        }
    }

    private func ensureLineStarts(upTo charIndex: Int) {
        guard let textView else { return }
        let text = textView.string as NSString
        let target = min(max(0, charIndex), text.length)
        if lineStartsValid && lineStarts.last.map({ $0 <= target }) == true {
            return
        }
        var index = lineStarts.last ?? 0
        while index < target {
            if text.character(at: index) == 10 {
                lineStarts.append(index + 1)
            }
            index += 1
        }
        if target >= text.length {
            lineStartsValid = true
        }
    }

    private func lineNumber(forCharIndex charIndex: Int) -> Int {
        ensureLineStarts(upTo: charIndex)
        var lo = 0
        var hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= charIndex {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo + 1
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
        if observedTextStorage !== textView.textStorage {
            attachToTextStorage(textView.textStorage)
        }
        attachToScrollView(textView.enclosingScrollView)
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let text = textView.string as NSString
        guard glyphRange.length > 0 || text.length == 0 else { return }

        let firstCharIndex = text.length == 0 ? 0 : layoutManager.characterIndexForGlyph(at: glyphRange.location)
        var lineNumber = lineNumber(forCharIndex: firstCharIndex)

        var glyphIndex = glyphRange.location
        while glyphIndex < NSMaxRange(glyphRange) {
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphLineRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let frect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil, withoutAdditionalLayout: true)
            let y = frect.minY + textView.textContainerInset.height - visibleRect.minY + 2
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 18, y: y), withAttributes: attributes)
            glyphIndex = NSMaxRange(glyphLineRange)
            lineNumber += 1
        }
    }
}
