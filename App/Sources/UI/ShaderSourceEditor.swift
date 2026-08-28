import AppKit
import SwiftUI

/// Monospaced GLSL editor: line numbers, 4-space tabs, rectangular editing,
/// auto-indent, syntax highlighting, and identifier completion.
struct ShaderSourceEditor: NSViewRepresentable {
    var text: String
    var diagnostics: [ShaderDiagnostic]
    var revealLine: Int?
    var revealNonce: Int
    var onChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> ShaderEditorHostView {
        let host = ShaderEditorHostView()
        context.coordinator.host = host
        context.coordinator.onChange = onChange
        host.setSource(text)
        host.setDiagnostics(diagnostics)
        host.textView.delegate = context.coordinator
        return host
    }

    func updateNSView(_ host: ShaderEditorHostView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.host = host
        context.coordinator.applyExternalTextIfNeeded(text)
        host.setDiagnostics(diagnostics)
        context.coordinator.revealLineIfNeeded(revealLine, nonce: revealNonce)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String) -> Void
        weak var host: ShaderEditorHostView?
        private var applyingExternalText = false
        private var lastRevealNonce = 0

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func applyExternalTextIfNeeded(_ newText: String) {
            guard let host, host.textView.string != newText else { return }
            applyingExternalText = true
            host.setSource(newText)
            applyingExternalText = false
        }

        func revealLineIfNeeded(_ line: Int?, nonce: Int) {
            guard nonce != lastRevealNonce, let line else { return }
            lastRevealNonce = nonce
            host?.revealLine(line)
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

    func setDiagnostics(_ diagnostics: [ShaderDiagnostic]) {
        var markers: [Int: ShaderDiagnostic.Severity] = [:]
        for diagnostic in diagnostics {
            guard let line = diagnostic.line else { continue }
            if markers[line] != .error {
                markers[line] = diagnostic.severity
            }
        }
        ruler.lineMarkers = markers
        ruler.needsDisplay = true
    }

    func revealLine(_ line: Int) {
        guard line >= 1 else { return }
        let nsString = textView.string as NSString
        var location = 0
        var current = 1
        while current < line, location < nsString.length {
            var lineEnd = 0
            nsString.getLineStart(nil, end: &lineEnd, contentsEnd: nil, for: NSRange(location: location, length: 0))
            if lineEnd <= location { break }
            location = lineEnd
            current += 1
        }
        let index = min(location, max(nsString.length, 1) - (nsString.length == 0 ? 0 : 1))
        var lineStart = 0
        var contentsEnd = 0
        nsString.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: index, length: 0))
        let range = NSRange(location: lineStart, length: max(contentsEnd - lineStart, 0))
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
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
        usesFontPanel = false
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
        textStorage?.delegate = self
        applyCodeAppearance()
    }

    /// NSColorPanel (used by inspector ColorPickers) sends `changeColor:` to
    /// the first responder. For a plain-text view that recolors the entire
    /// document; ignore it so picking a uniform does not restyle the shader.
    override func changeColor(_ sender: Any?) {}

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
            textStorage.beginEditing()
            textStorage.addAttributes(
                [.font: codeFont, .paragraphStyle: paragraphStyle],
                range: NSRange(location: 0, length: textStorage.length)
            )
            textStorage.endEditing()
            GLSLSyntaxHighlighter.highlight(textStorage)
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
            pendingAutoComplete = !isInsertingCompletion
                && string.utf16.count == 1
                && GLSLSyntaxHighlighter.isIdentifierChar(string.utf16.first!)
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

    /// ⌘/ toggles `//` on every line the selection touches. NSTextView has no
    /// action for this, and no default key equivalent claims the shortcut.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command,
           event.charactersIgnoringModifiers == "/",
           isEditable,
           window?.firstResponder === self {
            toggleLineComments()
            return true
        }
        return super.performKeyEquivalent(with: event)
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
        guard let layoutManager, textContainer != nil else { return .zero }
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

    // MARK: - Line comments

    private static let lineCommentMarker = "//"

    /// Comments every line the selection touches, or uncomments them when they
    /// all already start with `//`. Markers are aligned on the shallowest
    /// indentation in the selection, and the selection is mapped through the
    /// edits so it keeps covering the same text.
    private func toggleLineComments() {
        let nsString = string as NSString
        let selections = activeBlockRanges()
        let touched = lineRanges(touchedBy: selections, in: nsString)
        let nonBlank = touched.filter { $0.length > indentLength(of: $0, in: nsString) }
        let lines = nonBlank.isEmpty ? touched : nonBlank
        guard !lines.isEmpty else { return }

        let marker = Self.lineCommentMarker as NSString
        var edits: [(range: NSRange, replacement: String)] = []
        if lines.allSatisfy({ commentMarkerOffset(in: $0, of: nsString) != nil }) {
            for line in lines {
                guard let offset = commentMarkerOffset(in: line, of: nsString) else { continue }
                let markerEnd = offset + marker.length
                let followedBySpace = markerEnd < line.length
                    && nsString.character(at: line.location + markerEnd) == 0x20
                edits.append((
                    NSRange(location: line.location + offset, length: marker.length + (followedBySpace ? 1 : 0)),
                    ""
                ))
            }
        } else {
            let column = lines.map { indentLength(of: $0, in: nsString) }.min() ?? 0
            for line in lines {
                edits.append((
                    NSRange(location: line.location + min(column, line.length), length: 0),
                    Self.lineCommentMarker + " "
                ))
            }
        }
        guard !edits.isEmpty else { return }

        let newLength = edits.reduce(nsString.length) { total, edit in
            total + (edit.replacement as NSString).length - edit.range.length
        }
        applyReplacements(
            edits.map { ($0.range, $0.replacement) },
            selectionAfterEdit: selections.map { mapped($0, through: edits, newLength: newLength) }
        )
    }

    /// Content ranges (newline excluded) of every line any of `ranges` covers.
    /// A range ending exactly at a line start does not pull in that line.
    private func lineRanges(touchedBy ranges: [NSRange], in nsString: NSString) -> [NSRange] {
        var lines: [NSRange] = []
        var seenStarts = Set<Int>()
        for range in ranges {
            var location = min(max(range.location, 0), nsString.length)
            let end = min(max(NSMaxRange(range), location), nsString.length)
            repeat {
                var lineStart = 0
                var lineEnd = 0
                var contentsEnd = 0
                nsString.getLineStart(
                    &lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                    for: NSRange(location: location, length: 0)
                )
                if seenStarts.insert(lineStart).inserted {
                    lines.append(NSRange(location: lineStart, length: max(contentsEnd - lineStart, 0)))
                }
                if lineEnd <= location { break }
                location = lineEnd
            } while location < end
        }
        return lines.sorted { $0.location < $1.location }
    }

    private func indentLength(of line: NSRange, in nsString: NSString) -> Int {
        var length = 0
        while length < line.length {
            let character = nsString.character(at: line.location + length)
            guard character == 0x20 || character == 0x09 else { break }
            length += 1
        }
        return length
    }

    /// Offset of the leading `//` within `line`, or nil when it is not commented.
    private func commentMarkerOffset(in line: NSRange, of nsString: NSString) -> Int? {
        let marker = Self.lineCommentMarker as NSString
        let offset = indentLength(of: line, in: nsString)
        guard line.length - offset >= marker.length else { return nil }
        let candidate = NSRange(location: line.location + offset, length: marker.length)
        return nsString.substring(with: candidate) == Self.lineCommentMarker ? offset : nil
    }

    /// Maps a pre-edit selection range through a batch of non-overlapping edits
    /// so it still covers the same text afterwards. All comparisons use pre-edit
    /// coordinates, so the corrections are order independent.
    private func mapped(
        _ range: NSRange,
        through edits: [(range: NSRange, replacement: String)],
        newLength: Int
    ) -> NSRange {
        var location = range.location
        var length = range.length
        for edit in edits {
            let insertedLength = (edit.replacement as NSString).length
            // Text inserted exactly where a non-empty range starts belongs to
            // that range rather than pushing it forward.
            let insertionAtStart = edit.range.length == 0 && edit.range.location == range.location
            if NSMaxRange(edit.range) <= range.location, !(range.length > 0 && insertionAtStart) {
                location += insertedLength - edit.range.length
            } else if edit.range.location < range.location {
                // The range starts inside replaced text: pull the start back to
                // the edit and drop what the edit took from inside the range.
                let removedInside = max(min(NSMaxRange(edit.range), NSMaxRange(range)) - range.location, 0)
                location -= range.location - edit.range.location
                length = max(length - removedInside, 0)
            } else if range.length > 0, edit.range.location <= NSMaxRange(range) {
                let removedInside = max(min(NSMaxRange(edit.range), NSMaxRange(range)) - edit.range.location, 0)
                length = max(length + insertedLength - removedInside, 0)
            }
        }
        location = min(max(location, 0), newLength)
        length = min(max(length, 0), newLength - location)
        return NSRange(location: location, length: length)
    }

    private func applyReplacement(_ replacement: String) {
        applyReplacements(activeBlockRanges().map { ($0, replacement) })
    }

    private func applyReplacements(
        _ replacements: [(NSRange, String)],
        selectionAfterEdit: [NSRange]? = nil
    ) {
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

        let ordered = (selectionAfterEdit ?? carets).sorted { $0.location < $1.location }
        // A single explicit range is not a block caret; restoreBlockCarets()
        // ignores it, so it has to be applied directly.
        let single: NSRange? = selectionAfterEdit != nil && ordered.count == 1 ? ordered.first : nil
        blockCarets = ordered
        if let single {
            setSelectedRange(single)
        }
        restoreBlockCarets()
        isApplyingBlockEdit = false

        // `didChangeText()` resets to a single caret on the first line after
        // returning to the run loop; put the selection back.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let single {
                self.setSelectedRange(single)
            }
            self.restoreBlockCarets()
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

    // MARK: - Syntax highlighting

    private var highlightScheduled = false

    /// Coalesces highlight passes onto the next run-loop tick. Attribute
    /// changes must not happen while the storage is still processing an edit,
    /// and one pass per batch of edits is enough.
    fileprivate func scheduleHighlight() {
        guard !highlightScheduled else { return }
        highlightScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.highlightScheduled = false
            if let textStorage = self.textStorage {
                GLSLSyntaxHighlighter.highlight(textStorage)
            }
        }
    }

    // MARK: - Completion

    /// True while the completion session inserts (provisionally or finally)
    /// a completion, so those insertions don't re-trigger the popup.
    private var isInsertingCompletion = false
    /// Set when the user types an identifier character; consumed in
    /// `didChangeText()` to auto-open the completion popup.
    private var pendingAutoComplete = false

    override var rangeForUserCompletion: NSRange {
        let nsString = string as NSString
        let caret = min(selectedRange().location, nsString.length)
        var start = caret
        while start > 0, GLSLSyntaxHighlighter.isIdentifierChar(nsString.character(at: start - 1)) {
            start -= 1
        }
        return NSRange(location: start, length: caret - start)
    }

    override func completions(
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String]? {
        let nsString = string as NSString
        guard charRange.location != NSNotFound, NSMaxRange(charRange) <= nsString.length else { return nil }
        let prefix = nsString.substring(with: charRange)
        let matches = GLSLCompletion.completions(forPrefix: prefix, in: string)
        // No preselection: the default (0) provisionally inserts the first
        // match, which is too intrusive for a popup that opens while typing.
        index.pointee = -1
        return matches.isEmpty ? nil : matches
    }

    override func insertCompletion(
        _ word: String,
        forPartialWordRange charRange: NSRange,
        movement: Int,
        isFinal flag: Bool
    ) {
        isInsertingCompletion = true
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        isInsertingCompletion = false
    }

    override func didChangeText() {
        super.didChangeText()
        guard pendingAutoComplete else { return }
        pendingAutoComplete = false
        // Next tick: lets the pending highlight pass run first and keeps the
        // popup out of the middle of the `insertText` call stack.
        DispatchQueue.main.async { [weak self] in
            self?.autoCompleteIfAppropriate()
        }
    }

    private func autoCompleteIfAppropriate() {
        guard !isInsertingCompletion, activeBlockRanges().count <= 1 else { return }
        guard window?.firstResponder === self else { return }
        let selection = selectedRange()
        guard selection.length == 0 else { return }
        let completionRange = rangeForUserCompletion
        guard completionRange.length >= 2 else { return }
        let nsString = string as NSString
        // No popup for bare numeric literals or prose inside comments.
        guard !GLSLSyntaxHighlighter.isDigit(nsString.character(at: completionRange.location)) else { return }
        guard !GLSLSyntaxHighlighter.isInsideComment(nsString, at: selection.location) else { return }
        // `complete(_:)` beeps when the list is empty; check before invoking.
        let prefix = nsString.substring(with: completionRange)
        guard !GLSLCompletion.completions(forPrefix: prefix, in: string).isEmpty else { return }
        complete(nil)
    }
}

extension ShaderTextView: NSTextStorageDelegate {
    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        scheduleHighlight()
    }
}

final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    var lineMarkers: [Int: ShaderDiagnostic.Severity] = [:]

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
        return ceil(CGFloat(digits) * digitWidth) + 8 + markerSlot
    }

    private static let markerSlot: CGFloat = 12

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
                drawMarker(for: lineNumber, in: lineRect, relativePoint: relativePoint, inset: inset)
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
            drawMarker(
                for: lineNumber,
                in: layoutManager.extraLineFragmentRect,
                relativePoint: relativePoint,
                inset: inset
            )
        }
    }

    private func drawLineNumber(_ number: Int, in lineRect: NSRect, relativePoint: NSPoint, inset: NSSize) {
        let label = "\(number)" as NSString
        let color: NSColor
        switch lineMarkers[number] {
        case .error: color = .systemRed
        case .warning: color = .systemYellow
        case nil: color = .secondaryLabelColor
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont,
            .foregroundColor: color,
        ]
        let size = label.size(withAttributes: attributes)
        let point = NSPoint(
            x: bounds.maxX - size.width - 6,
            y: lineRect.minY + relativePoint.y + inset.height + (lineRect.height - size.height) / 2
        )
        label.draw(at: point, withAttributes: attributes)
    }

    private func drawMarker(for number: Int, in lineRect: NSRect, relativePoint: NSPoint, inset: NSSize) {
        guard let severity = lineMarkers[number] else { return }
        let diameter: CGFloat = 7
        let y = lineRect.minY + relativePoint.y + inset.height + (lineRect.height - diameter) / 2
        let rect = NSRect(x: 4, y: y, width: diameter, height: diameter)
        (severity == .error ? NSColor.systemRed : NSColor.systemYellow).setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
}
