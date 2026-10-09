import Foundation

/// Decodes the daemon's `S` snapshot frame and synthesises the ANSI byte
/// stream that repaints it into a libghostty surface.
///
/// This is what turns a reattach from M2's ring-replay tear into a clean
/// repaint: instead of replaying a torrent of historical escapes (which mangles
/// an idle TUI), the daemon's authoritative VT hands us the *current* grid and
/// we redraw exactly that frame, then live `D` bytes resume on top.
///
/// The host VT folds `inverse` into an fg/bg swap and `invisible` into a zero
/// codepoint before it packs the cell (see `fyolod/vt/src/lib.rs`), and the
/// `attributes` field is reserved-zero in this format version, so
/// bold/underline/italic are intentionally not carried here (they ride the v2
/// VT payload, and this format can gain them additively).
///
/// Colour is *not* resolved by the host. Each cell names a slot — default,
/// palette index, or an exact RGB the program itself chose — and this
/// synthesiser re-emits the slot rather than a colour, so libghostty applies
/// this viewer's theme. That is the whole point: a payload rendered by a
/// light-theme surface and a dark-theme surface must not look the same.
public enum FyolodSnapshot {
    /// Mirrors `WireColor` in `fyolod/src/protocol.rs`.
    public enum Color: Equatable {
        case `default`
        case palette(UInt8)
        case rgb(UInt8, UInt8, UInt8)

        /// SGR parameters selecting this colour, given the base code for the
        /// layer (30 foreground / 40 background).
        public func sgr(base: Int) -> String {
            switch self {
            // 39 / 49 hand the choice back to the terminal's own default.
            case .default: return "\(base + 9)"
            case .palette(let index): return "\(base + 8);5;\(index)"
            case .rgb(let r, let g, let b): return "\(base + 8);2;\(r);\(g);\(b)"
            }
        }
    }

    public struct Cell: Equatable {
        public var codepoint: UInt32
        public var foreground: Color
        public var background: Color
    }

    public struct Frame {
        public var rows: Int
        public var cols: Int
        public var cursorX: Int
        public var cursorY: Int
        public var alternateScreen: Bool
        public var title: String
        public var cells: [Cell]
        /// Set for payload v2 — the repaint, already in the terminal's own
        /// language. When present, `cells` is empty and `render` is a pass-through.
        public var vt: Data?
    }

    /// Snapshot payload v3 (see `encode_snapshot_payload` in `protocol.rs`):
    /// version:u8, rows/cols/cursor_x/cursor_y:u16be, alt_screen:u8,
    /// title_len:u16be, UTF-8 title, then row-major 16-byte cells —
    /// codepoint:u32be, fg colour (4), bg colour (4), attributes:u16be,
    /// 2 reserved bytes. Each colour is a tag byte then its value, zero-padded.
    ///
    /// v1 carried host-resolved RGB and is not accepted: it could not say
    /// "the client's default" or "palette index N", so it overrode the viewer's
    /// theme by construction.
    public static let formatVersion: UInt8 = 3
    /// Payload v2 carries VT sequences instead of packed cells. Preferred: the
    /// host describes screen *content* and this client's libghostty decides how
    /// it looks, so the local theme, the ANSI palette, and bold/underline/OSC 8
    /// all survive. Packed cells remain the fallback when the host's formatter
    /// fails, and the seed for a grid-diff client.
    public static let vtFormatVersion: UInt8 = 2
    public static let cellSize = 16
    public static let colorTagPalette: UInt8 = 1
    public static let colorTagRGB: UInt8 = 2

    public static func decode(_ payload: Data) -> Frame? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 12,
              bytes[0] == formatVersion || bytes[0] == vtFormatVersion
        else { return nil }
        let isVT = bytes[0] == vtFormatVersion

        func u16(_ offset: Int) -> Int { Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) }
        let rows = u16(1)
        let cols = u16(3)
        let cursorX = u16(5)
        let cursorY = u16(7)
        let alternateScreen = bytes[9] != 0
        let titleLength = u16(10)

        let cellsOffset = 12 + titleLength
        guard cellsOffset <= bytes.count,
              let title = String(bytes: bytes[12..<cellsOffset], encoding: .utf8)
        else { return nil }

        if isVT {
            // Format v2: the host serialised the screen back into VT sequences.
            // Nothing to synthesise — the bytes go straight to libghostty, which
            // is what lets the *viewer's* theme, palette and SGR handling apply.
            guard bytes.count >= cellsOffset + 4 else { return nil }
            let length = Int(bytes[cellsOffset]) << 24 | Int(bytes[cellsOffset + 1]) << 16
                | Int(bytes[cellsOffset + 2]) << 8 | Int(bytes[cellsOffset + 3])
            let start = cellsOffset + 4
            guard bytes.count == start + length else { return nil }
            return Frame(
                rows: rows, cols: cols, cursorX: cursorX, cursorY: cursorY,
                alternateScreen: alternateScreen, title: title, cells: [],
                vt: Data(bytes[start..<(start + length)])
            )
        }

        let cellCount = rows * cols
        guard bytes.count == cellsOffset + cellCount * cellSize else { return nil }

        // An unrecognised tag falls back to the terminal's default colour
        // rather than failing the frame, so the host can add tags additively.
        func color(_ start: Int) -> Color {
            switch bytes[start] {
            case colorTagPalette: return .palette(bytes[start + 1])
            case colorTagRGB: return .rgb(bytes[start + 1], bytes[start + 2], bytes[start + 3])
            default: return .default
            }
        }

        var cells = [Cell]()
        cells.reserveCapacity(cellCount)
        var offset = cellsOffset
        for _ in 0..<cellCount {
            let codepoint = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
            cells.append(Cell(
                codepoint: codepoint,
                foreground: color(offset + 4),
                background: color(offset + 8)
            ))
            offset += cellSize
        }

        return Frame(
            rows: rows, cols: cols, cursorX: cursorX, cursorY: cursorY,
            alternateScreen: alternateScreen, title: title, cells: cells
        )
    }

    /// Builds the repaint byte stream. Runs of cells sharing colours coalesce
    /// into one SGR + text run to keep the stream small. The result is
    /// idempotent — feeding it again repaints the same frame — so a mid-session
    /// keyframe (the resize barrier's fresh `S`) can reuse it verbatim.
    public static func render(_ frame: Frame) -> Data {
        // v2: the host already produced the repaint, prologue included. Replay it
        // verbatim — deciding anything about colour here is exactly the bug this
        // format exists to fix, and a client-side prelude is what the host-owned
        // prologue replaces. The old one was also asymmetric in the same way the
        // formatter is: it entered the alternate screen for an alt-screen frame
        // but never left it, so a primary-screen snapshot arriving while this
        // surface still sat in alt repainted onto the wrong buffer.
        if let vt = frame.vt {
            return vt
        }

        var output = String()
        // Alt-screen frames (vim, top) must repaint on the alternate buffer, or
        // the redraw lands on the primary screen and the live TUI paints over a
        // stale scrollback. Primary-screen frames leave the buffer alone.
        if frame.alternateScreen {
            output += "\u{1b}[?1049h"
        }
        output += "\u{1b}[2J\u{1b}[H"

        for row in 0..<frame.rows {
            output += "\u{1b}[\(row + 1);1H"
            var column = 0
            while column < frame.cols {
                let cell = frame.cells[row * frame.cols + column]
                // Extend the run while colours hold.
                var runEnd = column + 1
                while runEnd < frame.cols {
                    let next = frame.cells[row * frame.cols + runEnd]
                    if next.foreground != cell.foreground || next.background != cell.background {
                        break
                    }
                    runEnd += 1
                }
                output += "\u{1b}[\(cell.foreground.sgr(base: 30));\(cell.background.sgr(base: 40))m"
                for index in column..<runEnd {
                    let point = frame.cells[row * frame.cols + index].codepoint
                    output.unicodeScalars.append(Unicode.Scalar(point == 0 ? 32 : point)
                        ?? Unicode.Scalar(32))
                }
                column = runEnd
            }
        }

        output += "\u{1b}[0m\u{1b}[\(frame.cursorY + 1);\(frame.cursorX + 1)H"
        return Data(output.utf8)
    }
}
