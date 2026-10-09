import GhosttyTheme

/// fyolo's own themes, shipped inside the app. They resolve after the user's
/// `Themes` folder (so a file of the same name still overrides them) and before
/// the Ghostty catalog, and the pickers list them beside the built-ins.
@MainActor
enum BundledThemes {
    static let all: [GhosttyThemeDefinition] = [
        ThemeLibrary.parse(name: "FLO", contents: flo),
    ].compactMap { $0 }

    /// The default dark theme: IR Black on a pure-black canvas.
    static let floName = "FLO"

    private static let flo = """
    background = #000000
    foreground = #f1f1f1
    cursor-color = #808080
    cursor-text = #ffffff
    selection-background = #b5d5ff
    selection-foreground = #000000
    palette = 0=#4f4f4f
    palette = 1=#fa6c60
    palette = 2=#a8ff60
    palette = 3=#fffeb7
    palette = 4=#96cafe
    palette = 5=#fa73fd
    palette = 6=#c6c5fe
    palette = 7=#efedef
    palette = 8=#7b7b7b
    palette = 9=#fcb6b0
    palette = 10=#cfffab
    palette = 11=#ffffcc
    palette = 12=#b5dcff
    palette = 13=#fb9cfe
    palette = 14=#e0e0fe
    palette = 15=#ffffff
    """
}
