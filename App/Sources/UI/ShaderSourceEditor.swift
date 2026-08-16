import AppKit
import SwiftUI

/// Monospaced GLSL editor: line numbers, 4-space tabs, rectangular editing, auto-indent.
struct ShaderSourceEditor: NSViewRepresentable {
    var text: String
    var onChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> ShaderEditorHostView {
        let host = ShaderEditorHostView()
        context.coordinator.host = host
        context.coordinator.onChange = onChange
        host.setSource(text)
        host.textView.delegate = context.coordinator
        return host
    }

    func updateNSView(_ host: ShaderEditorHostView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.host = host
        context.coordinator.applyExternalTextIfNeeded(text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String) -> Void
        weak var host: ShaderEditorHostView?
        private var applyingExternalText = false

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func applyExternalTextIfNeeded(_ newText: String) {
            guard let host, host.textView.string != newText else { return }
            applyingExternalText = true
            host.setSource(newText)
            applyingExternalText = false
        }

        func textDidChange(_ notification: Notification) {
            host?.ruler.refresh()
            guard !applyingExternalText, let textView = host?.textView else { return }
            onChange(textView.string)
        }
    }
}

final class ShaderEditorHostView: NSView {
    let scrollView = NSScrollView()
    let textView: ShaderTextView
    let ruler: LineNumberRulerView

    override init(frame frameRect: NSRect) {
        // Explicit TextKit 1 stack. `textContainer: nil` selects TextKit 2 on
        // recent macOS, which leaves this view blank and gives the ruler no glyphs.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        container.lineFragmentPadding = 4
        layoutManager.addTextContainer(container)

        textView = ShaderTextView(frame: NSRect(origin: .zero, size: NSSize(width: 200, height: 200)), textContainer: container)
        scrollView.documentView = textView
        ruler = LineNumberRulerView(textView: textView)
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.focusRingType = .none
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.verticalRulerView = ruler
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = bounds

        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSource(_ text: String) {
        textView.string = text
        textView.applyCodeAppearance()
        // Thickness first so NSScrollView can inset the clip view before we
        // size the document. Doing this after tile left text under the gutter.
        ruler.refresh()
        tileTextView()
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        needsDisplay = true
        textView.needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        scrollView.tile()
        tileTextView()
    }

    /// Sizes the text view to the clip view *after* the ruler has been tiled,
    /// so wrapping uses the visible width and the document cannot slide under
    /// the gutter or grow a horizontal scroller.
    private func tileTextView() {
        scrollView.tile()
        let clip = scrollView.contentView.bounds.size
        let width = max(floor(clip.width), 1)
        let minHeight = max(floor(clip.height), 1)

        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: width, height: minHeight)
        textView.maxSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        var height = minHeight
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: textView.string.utf16.count), actualCharacterRange: nil)
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            height = max(minHeight, ceil(used.maxY + textView.textContainerInset.height * 2 + 8))
        }
        textView.setFrameSize(NSSize(width: width, height: height))
        textView.setFrameOrigin(.zero)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        scrollView.backgroundColor = .textBackgroundColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        textView.applyCodeAppearance()
    }
}

final class ShaderTextView: NSTextView {
    static let fontSize: CGFloat = 13
    static let tabWidthInSpaces = 4

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticDataDetectionEnabled = false
        smartInsertDeleteEnabled = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = NSSize(width: 6, height: 8)
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = false
        applyCodeAppearance()
    }

    func applyCodeAppearance() {
        let codeFont = NSFont.monospacedSystemFont(ofSize: Self.fontSize, weight: .regular)
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: codeFont]).width
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.tabStops = []
        paragraphStyle.defaultTabInterval = spaceWidth * CGFloat(Self.tabWidthInSpaces)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: codeFont,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraphStyle,
        ]
        typingAttributes = attributes
        defaultParagraphStyle = paragraphStyle
        font = codeFont
        textColor = .textColor
        backgroundColor = .textBackgroundColor
        insertionPointColor = .textColor
        selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
        ]

        if let textStorage, textStorage.length > 0 {
            textStorage.addAttributes(attributes, range: NSRange(location: 0, length: textStorage.length))
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCodeAppearance()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawBlockCarets(in: dirtyRect)
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        insertionPointVisible = flag
        if blockCarets.count > 1, blockCarets.allSatisfy({ $0.length == 0 }) {
            invalidateBlockCaretDisplay()
            return
        }
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        if blockCarets.count > 1 {
            invalidateBlockCaretDisplay()
        }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let string = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        let ranges = activeBlockRanges()
        if ranges.count <= 1 {
            if replacementRange.location != NSNotFound {
                setSelectedRange(replacementRange)
            }
            super.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0))
            blockCarets = []
            return
        }
        applyReplacements(ranges.map { ($0, string) })
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !isRestoringBlockCarets, !stillSelecting else { return }
        if ranges.count > 1 {
            blockCarets = ranges.map(\.rangeValue)
        } else if !isApplyingBlockEdit {
            blockCarets = []
        }
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            insertNewlinePreservingIndent()
        case #selector(insertTab(_:)):
            applyReplacement("\t")
        case #selector(deleteBackward(_:)) where activeBlockRanges().count > 1:
            deleteInSelections(forward: false)
        case #selector(deleteForward(_:)) where activeBlockRanges().count > 1:
            deleteInSelections(forward: true)
        default:
            super.doCommand(by: selector)
        }
    }

    override func paste(_ sender: Any?) {
        guard let pasted = NSPasteboard.general.string(forType: .string) else {
            super.paste(sender)
            return
        }
        let ranges = activeBlockRanges()
        guard ranges.count > 1 else {
            super.paste(sender)
            return
        }
        let lines = pasted.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let ordered = ranges.sorted { $0.location < $1.location }
        if lines.count == ordered.count {
            applyReplacements(zip(ordered, lines).map { ($0, $1) })
        } else {
            applyReplacement(pasted)
        }
    }

    private func insertNewlinePreservingIndent() {
        let pairs = activeBlockRanges().map { range -> (NSRange, String) in
            (range, "\n" + leadingWhitespace(at: range.location))
        }
        applyReplacements(pairs)
    }

    private func deleteInSelections(forward: Bool) {
        let nsString = string as NSString
        let pairs = activeBlockRanges().compactMap { range -> (NSRange, String)? in
            let deletion = deletionRange(for: range, forward: forward, in: nsString)
            guard deletion.length > 0 else { return nil }
            return (deletion, "")
        }
        applyReplacements(pairs)
    }

    private func deletionRange(for range: NSRange, forward: Bool, in string: NSString) -> NSRange {
        if range.length > 0 { return range }
        if forward {
            guard range.location < string.length else { return range }
            return string.rangeOfComposedCharacterSequence(at: range.location)
        }
        guard range.location > 0 else { return range }
        return string.rangeOfComposedCharacterSequence(at: range.location - 1)
    }

    private func leadingWhitespace(at location: Int) -> String {
        let nsString = string as NSString
        let clamped = min(max(location, 0), nsString.length)
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        nsString.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: clamped, length: 0))
        let line = nsString.substring(with: NSRange(location: lineStart, length: max(contentsEnd - lineStart, 0)))
        return String(line.prefix { $0 == " " || $0 == "\t" })
    }

    private var selectedNSRanges: [NSRange] {
        selectedRanges.map(\.rangeValue)
    }

    /// NSTextView drops extra insertion points after the first edit. Keep the
    /// block carets here until the user clicks or makes a normal selection.
    private var blockCarets: [NSRange] = []
    private var isApplyingBlockEdit = false
    private var isRestoringBlockCarets = false
    private var insertionPointVisible = true

    private func activeBlockRanges() -> [NSRange] {
        let current = selectedNSRanges
        if current.count > 1 { return current }
        if blockCarets.count > 1 { return blockCarets }
        return current
    }

    private func drawBlockCarets(in dirtyRect: NSRect) {
        guard shouldDrawInsertionPoint, insertionPointVisible, blockCarets.count > 1,
              blockCarets.allSatisfy({ $0.length == 0 }) else { return }
        insertionPointColor.setFill()
        for caret in blockCarets {
            var rect = caretRect(atCharacterIndex: caret.location)
            rect.size.width = max(rect.width, 1)
            if dirtyRect.intersects(rect) {
                rect.fill()
            }
        }
    }

    private func invalidateBlockCaretDisplay() {
        for caret in blockCarets {
            setNeedsDisplay(caretRect(atCharacterIndex: caret.location).insetBy(dx: -2, dy: 1))
        }
    }

    private func caretRect(atCharacterIndex rawIndex: Int) -> NSRect {
        guard let layoutManager, let textContainer else { return .zero }
        let nsString = string as NSString
        let index = min(max(rawIndex, 0), nsString.length)
        let origin = textContainerOrigin

        if index >= nsString.length || layoutManager.numberOfGlyphs == 0 {
            var rect = layoutManager.extraLineFragmentRect
            if rect == .zero, layoutManager.numberOfGlyphs > 0 {
                let lastGlyph = layoutManager.numberOfGlyphs - 1
                rect = layoutManager.lineFragmentUsedRect(
                    forGlyphAt: lastGlyph,
                    effectiveRange: nil,
                    withoutAdditionalLayout: true
                )
                rect.origin.x = rect.maxX
            }
            rect.origin.x += origin.x
            rect.origin.y += origin.y
            rect.size.width = 1
            if rect.height < 1 {
                rect.size.height = font?.boundingRectForFont.height ?? 16
            }
            return rect
        }

        let glyphIndex = min(
            layoutManager.glyphIndexForCharacter(at: index),
            max(layoutManager.numberOfGlyphs, 1) - 1
        )
        let lineRect = layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: nil,
            withoutAdditionalLayout: true
        )
        let location = layoutManager.location(forGlyphAt: glyphIndex)
        var x = lineRect.minX + location.x
        if index < nsString.length, nsString.substring(with: NSRange(location: index, length: 1)) == "\n" {
            let used = layoutManager.lineFragmentUsedRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil,
                withoutAdditionalLayout: true
            )
            x = used.maxX
        }
        var rect = NSRect(x: x, y: lineRect.minY, width: 1, height: max(lineRect.height, 1))
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        return rect
    }

    private func applyReplacement(_ replacement: String) {
        applyReplacements(activeBlockRanges().map { ($0, replacement) })
    }

    private func applyReplacements(_ replacements: [(NSRange, String)]) {
        guard !replacements.isEmpty, let textStorage else { return }
        let sorted = replacements.sorted { $0.0.location > $1.0.location }
        let values = sorted.map { NSValue(range: $0.0) }
        let strings = sorted.map(\.1)
        guard shouldChangeText(inRanges: values, replacementStrings: strings) else { return }

        isApplyingBlockEdit = true
        var carets: [NSRange] = []
        textStorage.beginEditing()
        for (range, replacement) in sorted {
            let newLength = (replacement as NSString).length
            textStorage.replaceCharacters(in: range, with: replacement)
            let delta = newLength - range.length
            carets = carets.map { NSRange(location: $0.location + delta, length: 0) }
            carets.append(NSRange(location: range.location + newLength, length: 0))
        }
        textStorage.endEditing()
        didChangeText()

        let orderedCarets = carets.sorted { $0.location < $1.location }
        blockCarets = orderedCarets
        restoreBlockCarets()
        isApplyingBlockEdit = false

        // `didChangeText()` resets to a single caret on the first line after
        // returning to the run loop; put the block carets back.
        DispatchQueue.main.async { [weak self] in
            self?.restoreBlockCarets()
        }
    }

    private func restoreBlockCarets() {
        guard blockCarets.count > 1 else { return }
        isRestoringBlockCarets = true
        setSelectedRanges(blockCarets.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
        isRestoringBlockCarets = false
        if let first = blockCarets.first {
            scrollRangeToVisible(first)
        }
        invalidateBlockCaretDisplay()
    }
}

final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        ruleThickness = Self.thickness(forLineCount: 1)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// NSScrollView tiles using this, not `ruleThickness`. Leaving the default
    /// marker reservation made the gutter much wider than the labels.
    override var requiredThickness: CGFloat {
        Self.thickness(forLineCount: lineCount)
    }

    func refresh() {
        let thickness = requiredThickness
        if abs(ruleThickness - thickness) > 0.5 {
            ruleThickness = thickness
        }
        needsDisplay = true
        scrollView?.tile()
    }

    private var lineCount: Int {
        max(textView?.string.components(separatedBy: "\n").count ?? 1, 1)
    }

    private static func thickness(forLineCount count: Int) -> CGFloat {
        let digits = max(String(count).count, 2)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: labelFont]).width
        return ceil(CGFloat(digits) * digitWidth) + 10
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        separator.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        separator.stroke()

        let relativePoint = convert(NSPoint.zero, from: textView)
        let inset = textView.textContainerInset
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let nsString = textView.string as NSString

        var lineNumber = 1
        if glyphRange.location > 0 {
            let firstChar = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            var newlineCount = 0
            nsString.enumerateSubstrings(
                in: NSRange(location: 0, length: firstChar),
                options: [.byLines, .substringNotRequired]
            ) { _, _, enclosing, _ in
                if NSMaxRange(enclosing) <= firstChar {
                    newlineCount += 1
                }
            }
            lineNumber += newlineCount
        }

        var glyphIndex = glyphRange.location
        let glyphEnd = NSMaxRange(glyphRange)
        while glyphIndex < glyphEnd {
            var lineGlyphRange = NSRange()
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineGlyphRange, withoutAdditionalLayout: true)
            let charIndex = layoutManager.characterIndexForGlyph(at: lineGlyphRange.location)
            let isLineStart = charIndex == 0 || nsString.substring(with: NSRange(location: charIndex - 1, length: 1)) == "\n"
            if isLineStart {
                drawLineNumber(lineNumber, in: lineRect, relativePoint: relativePoint, inset: inset)
                lineNumber += 1
            }
            glyphIndex = NSMaxRange(lineGlyphRange)
        }

        if layoutManager.extraLineFragmentTextContainer != nil {
            drawLineNumber(
                lineNumber,
                in: layoutManager.extraLineFragmentRect,
                relativePoint: relativePoint,
                inset: inset
            )
        }
    }

    private func drawLineNumber(_ number: Int, in lineRect: NSRect, relativePoint: NSPoint, inset: NSSize) {
        let label = "\(number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = label.size(withAttributes: attributes)
        let point = NSPoint(
            x: bounds.maxX - size.width - 6,
            y: lineRect.minY + relativePoint.y + inset.height + (lineRect.height - size.height) / 2
        )
        label.draw(at: point, withAttributes: attributes)
    }

    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
}
