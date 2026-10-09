/// The built-in themes: well-known Ghostty scheme names, in display order — the
/// dark ones, then the light ones, split by each theme's own background
/// luminance. `ThemeLibraryTests` is where the tally lives; restating it here
/// only creates a second number to forget.
///
/// Shared because the Mac's theme picker and the iPhone's offer the same set, and
/// two hand-kept copies would drift. Names only: both ends resolve them against
/// `GhosttyThemeCatalog` to render, and that meaning does not belong in this
/// package.
///
/// Curated, not exhaustive. No two *unrelated* entries read as the same theme —
/// measured as weighted mean CIE Lab distance over background, foreground, and
/// ANSI 1–6, with every cross-family pair clearing ΔE 11, which is what keeps a
/// scheme from arriving twice under two names (TokyoNight Night vs Storm 2.6).
/// The list's own tightest pair is Catppuccin Frappé against Nord at 11.3.
///
/// Flavors of one family are exempt because listing them is a deliberate act, not
/// an oversight: Catppuccin's three dark flavors sit at 4.3–8.6 of each other and
/// are still all here, since the flavor name is exactly what its users pick
/// between. `ThemeLibraryTests` enforces the resolve, the brightness split, and
/// the distance rule.
public enum BuiltInThemes {
    public static let names: [String] = [
        "Dracula",
        "Catppuccin Mocha",
        "Catppuccin Macchiato",
        "Catppuccin Frappe",
        "TokyoNight Night",
        "Nord",
        "Gruvbox Dark",
        "Atom One Dark",
        "Monokai Pro",
        "Rose Pine",
        "Ayu Mirage",
        "Night Owl",
        "Kanagawa Wave",
        "Kanagawa Dragon",
        "Everforest Dark Hard",
        "GitHub Dark Default",
        "iTerm2 Solarized Dark",
        "Cobalt2",
        "Vesper",
        "Flexoki Dark",
        "Melange Dark",
        "Xcode Dark",
        "Aura",
        "Dark Modern",
        "Oxocarbon",
        "Gruber Darker",
        "Jellybeans",
        "Horizon",
        "Embark",
        "Srcery",
        "Terafox",
        "Modus Vivendi",
        "Vercel",
        "Poimandres",
        "Matte Black",
        "Carbonfox",
        "Sonokai",
        "Shades Of Purple",
        "Zenburn",
        "Blue Matrix",
        "Homebrew",
        "IR Black",
        "Ocean",
        "Espresso",
        "traffic",
        "Miasma",
        "Arthur",
        "Catppuccin Latte",
        "GitHub Light Default",
        "Rose Pine Dawn",
        "Gruvbox Light",
        "iTerm2 Solarized Light",
        "Atom One Light",
        "Flexoki Light",
        "Kanagawa Lotus",
        "Xcode Light",
        "Monokai Pro Light",
        "Iceberg Light",
        "Melange Light",
        "One Half Light",
        "Modus Operandi",
        "Bluloco Light",
        "Horizon Bright",
        "Material",
        "Neobones Light",
        "Nvim Light",
        "Coffee Theme",
        "Novel",
        "Belafonte Day",
    ]
}
