import AppKit

/// VS Code's `editor.guides.indentation` for the inspector's code editor: a thin vertical rule at
/// every indent level a line sits inside, painted behind the text. The editor lives in a narrow
/// column and is mostly used to *read* agent-written code, where the line that opened the block has
/// usually scrolled off the top — the rules are what say how deep you are.
///
/// An instance is held by the text view so the derived indent width survives between draws;
/// everything else is recomputed per paint from the visible range only.
@MainActor
final class IndentGuideRenderer {
    /// A rule is one point wide, snapped to the backing store — two device pixels on Retina, the
    /// same weight VS Code's guides carry.
    private static let thickness: CGFloat = 1

    /// How far the walk may run past the viewport looking for the non-blank line a blank run takes
    /// its guides from. A cap, because a document can open with a thousand empty lines.
    private static let blankRunLimit = 64

    /// The indent width last derived, tagged with the document length it came from.
    private var cachedUnit: (documentLength: Int, unit: Int)?

    /// Paints the guides for the lines currently on screen. `dirtyRect` only gates the fills —
    /// AppKit's copy-on-scroll hands us a thin strip, and a rule outside it is already on screen.
    func draw(in textView: NSTextView, dirtyRect: NSRect, color: NSColor) {
        guard color.alphaComponent > 0 else { return }
        let rules = self.rules(in: textView)
        guard !rules.isEmpty else { return }
        color.setFill()
        for rule in rules where rule.intersects(dirtyRect) { rule.fill() }
    }

    /// Every guide rule for the lines currently on screen, in the text view's own coordinates and
    /// already snapped to the backing store. Split from `draw` so the geometry can be checked
    /// against a laid-out text view instead of only by eye.
    func rules(in textView: NSTextView) -> [NSRect] {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return [] }
        let content = textView.string as NSString
        guard content.length > 0 else { return [] }
        // A file that never nests yields no levels on any line, so no rules — the detected width
        // is only ever a divisor here, never something that invents indentation.
        let unit = indentUnit(in: content)

        let origin = textView.textContainerOrigin
        var viewport = textView.visibleRect
        viewport.origin.x -= origin.x
        viewport.origin.y -= origin.y
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: viewport, in: container)
        let visible = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        guard visible.length > 0 else { return [] }

        // Blank lines inside a block keep the block's rules, so a run straddling the top or bottom
        // edge of the viewport needs the non-blank neighbour just outside it.
        let scan = Self.scanRange(around: visible, in: content)

        // Where the last non-blank line put its rules, so a blank run can inherit the positions
        // rather than re-derive them from indentation it doesn't have — which is also what keeps
        // the carried rules correct in a tab-indented file.
        var previousLevelXs: [CGFloat] = []
        var pendingBlanks: [NSRect] = []
        var rules: [NSRect] = []

        content.enumerateSubstrings(
            in: scan,
            options: [.byParagraphs, .substringNotRequired]
        ) { _, lineRange, _, _ in
            let indent = EditorIndentation.leading(of: lineRange, in: content).length
            let extent = self.rows(of: lineRange, layoutManager: layoutManager, in: container)
            // An all-whitespace line indents nothing of its own; it waits for the line below.
            guard indent < lineRange.length else {
                pendingBlanks.append(extent)
                return
            }

            var levelXs: [CGFloat] = []
            levelXs.reserveCapacity(indent / unit)
            for level in 0..<(indent / unit) {
                guard let x = self.columnX(
                    at: lineRange.location + level * unit, layoutManager: layoutManager
                ) else { break }
                levelXs.append(x + origin.x)
            }

            if !pendingBlanks.isEmpty {
                // VS Code carries the guides straight through a blank run, at the shallower of the
                // two lines bracketing it: a blank line between two statements keeps the block's
                // rules, and one that closes a block doesn't sprout a deeper rule out of nothing.
                let carried = previousLevelXs.prefix(levelXs.count)
                for blank in pendingBlanks {
                    rules.append(contentsOf: Self.rules(at: carried, over: blank, in: textView))
                }
                pendingBlanks.removeAll(keepingCapacity: true)
            }
            // One rule per level spanning the whole logical line — including its soft-wrapped
            // rows. A continuation row has no indentation of its own to read, so deriving guides
            // per visual row is what invents the spurious ones.
            rules.append(contentsOf: Self.rules(at: levelXs[...], over: extent, in: textView))
            previousLevelXs = levelXs
        }
        // A blank run reaching the end of the document has no lower neighbour to inherit from, so
        // it draws nothing — the same answer VS Code gives past the last line of code.
        return rules
    }

    private static func rules(
        at columns: ArraySlice<CGFloat>, over extent: NSRect, in textView: NSTextView
    ) -> [NSRect] {
        guard extent.height > 0 else { return [] }
        let top = extent.minY + textView.textContainerOrigin.y
        return columns.map { x in
            // Snapped to whole device pixels or a one-point rule lands across a pixel boundary and
            // renders as a blurry smear that shimmers under scrolling. The vertical edges round
            // outward so consecutive lines' rules meet without a hairline gap between them.
            textView.backingAlignedRect(
                NSRect(x: x, y: top, width: thickness, height: extent.height),
                options: [.alignMinXNearest, .alignWidthNearest, .alignMinYOutward, .alignMaxYOutward]
            )
        }
    }

    /// Where the character at `index` starts, in text-container coordinates. Asking the layout
    /// manager rather than multiplying a column by an advance keeps the rules correct for tab
    /// indentation, whose width is the view's tab stops rather than the font's.
    private func columnX(at index: Int, layoutManager: NSLayoutManager) -> CGFloat? {
        let glyphs = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil
        )
        guard glyphs.length > 0, glyphs.location < layoutManager.numberOfGlyphs else { return nil }
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        return fragment.minX + layoutManager.location(forGlyphAt: glyphs.location).x
    }

    /// The vertical band a logical line occupies, wrapped rows included. An empty line has no
    /// glyphs to measure, so its fragment rect stands in.
    private func rows(
        of lineRange: NSRange, layoutManager: NSLayoutManager, in container: NSTextContainer
    ) -> NSRect {
        if lineRange.length > 0 {
            let glyphs = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            if glyphs.length > 0 {
                return layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            }
        }
        let anchor = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: lineRange.location, length: 0), actualCharacterRange: nil
        )
        guard anchor.location < layoutManager.numberOfGlyphs else {
            return layoutManager.extraLineFragmentRect
        }
        return layoutManager.lineFragmentRect(forGlyphAt: anchor.location, effectiveRange: nil)
    }

    // MARK: Indent width

    /// Whitespace characters per level, from the buffer's own indentation. `EditorIndentation`
    /// owns the detection because it owns the *answer*: it is what Return and Tab insert, so a
    /// second opinion here would draw the rules at columns the Tab key never produces. A
    /// tab-indented file is one character per level whatever width the view renders it at.
    ///
    /// Cached against the document length. Scrolling is the hot path and never changes the
    /// length, so it never re-derives; an edit does, which is both cheap and exactly when the
    /// answer could have moved.
    private func indentUnit(in content: NSString) -> Int {
        if let cached = cachedUnit, cached.documentLength == content.length { return cached.unit }
        let detected = EditorIndentation.detected(in: content)
        let unit = detected.usesTabs ? 1 : max(1, detected.width)
        cachedUnit = (content.length, unit)
        return unit
    }

    // MARK: Line helpers

    /// The visible range grown to whole lines, then out past any blank run at either edge to the
    /// non-blank line that run inherits its guides from.
    static func scanRange(around visible: NSRange, in content: NSString) -> NSRange {
        var start = content.lineRange(for: NSRange(location: visible.location, length: 0)).location
        var steps = 0
        while start > 0, steps < blankRunLimit,
              EditorIndentation.isBlank(content.lineRange(for: NSRange(location: start, length: 0)), in: content) {
            start = content.lineRange(for: NSRange(location: start - 1, length: 0)).location
            steps += 1
        }

        let last = min(max(NSMaxRange(visible) - 1, 0), max(content.length - 1, 0))
        var end = NSMaxRange(content.lineRange(for: NSRange(location: last, length: 0)))
        steps = 0
        while end < content.length, steps < blankRunLimit,
              EditorIndentation.isBlank(content.lineRange(for: NSRange(location: end - 1, length: 0)), in: content) {
            end = NSMaxRange(content.lineRange(for: NSRange(location: end, length: 0)))
            steps += 1
        }
        return NSRange(location: start, length: max(0, end - start))
    }
}
