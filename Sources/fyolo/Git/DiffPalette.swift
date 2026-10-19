import AppKit

/// The diff's add/delete tints: `Palette`'s green and red at its `wash` strength, mixed
/// into the pane's actual background. An alpha wash drifts in hue and strength with
/// whatever terminal background is configured — firm on one theme, invisible on the next,
/// and rarely equal between the add and delete sides. A fixed fraction mixed in Oklab
/// holds both sides at the same apparent strength on any background.
struct DiffPalette {
    /// Full-row washes, painted by the layout manager behind the text.
    let additionWash: NSColor
    let deletionWash: NSColor
    /// The deeper tint marking the changed span inside a modified line. Opaque, and
    /// mixed from the wash rather than layered over it, so the span's strength does not
    /// depend on how TextKit happens to composite two translucent passes.
    let additionEmphasis: NSColor
    let deletionEmphasis: NSColor
    /// The gutter's share of a changed row, mixed a step stronger than the row's wash.
    /// github.com does the same: the number cell reads as the row's anchor rather than as
    /// the same flat tint running edge to edge, and the digits stay in neutral ink.
    let additionGutter: NSColor
    let deletionGutter: NSColor
    /// A collapsed band's row fill, and the filled gutter cell that acts as its button.
    /// Neutral rather than github.com's blue — an accent-colored block would be the one
    /// loud thing in the pane.
    let bandFill: NSColor
    let bandControlFill: NSColor

    init(background: NSColor, isDark: Bool) {
        let addition = Palette.base(.green, dark: isDark)
        let deletion = Palette.base(.red, dark: isDark)
        let washAmount = Palette.Strength.wash.amount(dark: isDark)
        let emphasisAmount: CGFloat = isDark ? 0.26 : 0.20
        let ink = isDark ? NSColor.white : NSColor.black

        additionWash = Palette.fill(.green, .wash, on: background, dark: isDark)
        deletionWash = Palette.fill(.red, .wash, on: background, dark: isDark)
        additionEmphasis = Palette.mix(additionWash, addition, emphasisAmount)
        deletionEmphasis = Palette.mix(deletionWash, deletion, emphasisAmount)
        additionGutter = Palette.mix(background, addition, washAmount * 1.6)
        deletionGutter = Palette.mix(background, deletion, washAmount * 1.6)
        bandFill = Palette.mix(background, ink, 0.05)
        bandControlFill = Palette.mix(background, ink, 0.11)
    }

    /// The fill behind a row's text.
    func wash(for role: DiffDocument.Line.Role) -> NSColor? {
        switch role {
        case .code(.addition): return additionWash
        case .code(.deletion): return deletionWash
        case .band: return bandFill
        case .code: return nil
        }
    }

    /// Changed gutters anchor the row; bands reserve the stronger fill for button hover.
    func gutterFill(for role: DiffDocument.Line.Role) -> NSColor? {
        switch role {
        case .code(.addition): return additionGutter
        case .code(.deletion): return deletionGutter
        case .band: return bandFill
        case .code: return nil
        }
    }
}
