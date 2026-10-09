//! Turning what the VT engine holds into what the protocol carries.
//!
//! Pure translation: no session, no client, no PTY. A cell becomes a `WireCell`,
//! a damage set becomes a `G` payload, a scrollback capture becomes a run of `H`
//! frames sized to fit the frame limit. Everything here is a function of its
//! arguments, which is why it can be read — and tested — without a session.

use crate::protocol::{
    encode_history_payload, GridDiff, GridRow, HistoryChunk, WireCell, WireColor,
    HISTORY_HEADER_SIZE, MAX_HISTORY_FRAME_SIZE, SNAPSHOT_CELL_SIZE,
};
use bytes::Bytes;
use std::collections::VecDeque;

/// How much encoded scrollback one attach may stage. The rows are held in
/// memory until the client drains them, so this is a per-attachment cost.
pub(crate) const SCROLLBACK_STAGE_MAX_BYTES: usize = 1024 * 1024;

/// How many rows of `cols` columns fit in the staging budget.
pub(crate) fn scrollback_row_limit(cols: u16) -> usize {
    let row_bytes = usize::from(cols).saturating_mul(SNAPSHOT_CELL_SIZE);
    SCROLLBACK_STAGE_MAX_BYTES
        .checked_div(row_bytes)
        .unwrap_or(0)
}

/// Pack captured scrollback into `H` payloads, each one whole rows and none of
/// them over the frame limit. Offsets count back from the live screen, so the
/// first chunk starts at 1.
pub(crate) fn encode_scrollback_chunks(
    cols: u16,
    rows: Vec<Vec<fyolod_vt::Cell>>,
) -> Result<VecDeque<Bytes>, String> {
    if rows.is_empty() {
        return Ok(VecDeque::new());
    }
    let row_bytes = usize::from(cols)
        .checked_mul(SNAPSHOT_CELL_SIZE)
        .ok_or_else(|| "scrollback row length overflow".to_string())?;
    let rows_per_chunk = MAX_HISTORY_FRAME_SIZE
        .checked_sub(HISTORY_HEADER_SIZE)
        .and_then(|available| available.checked_div(row_bytes))
        .unwrap_or(0)
        .min(usize::from(u16::MAX));
    if rows_per_chunk == 0 {
        return Err(format!(
            "one {cols}-column row cannot fit in a {MAX_HISTORY_FRAME_SIZE}-byte H frame"
        ));
    }

    let mut rows = rows.into_iter();
    let mut chunks = VecDeque::new();
    let mut first_offset = 1u32;
    loop {
        let mut cells = Vec::with_capacity(rows_per_chunk * usize::from(cols));
        let mut row_count = 0u16;
        for _ in 0..rows_per_chunk {
            let Some(row) = rows.next() else {
                break;
            };
            if row.len() != usize::from(cols) {
                return Err(format!(
                    "scrollback row has {} cells, expected {cols}",
                    row.len()
                ));
            }
            cells.extend(row.into_iter().map(wire_cell));
            row_count += 1;
        }
        if row_count == 0 {
            break;
        }
        let payload = encode_history_payload(&HistoryChunk {
            cols,
            first_offset,
            row_count,
            cells,
        })
        .map_err(|error| error.to_string())?;
        chunks.push_back(Bytes::from(payload));
        first_offset = first_offset
            .checked_add(u32::from(row_count))
            .ok_or_else(|| "scrollback offset overflow".to_string())?;
    }
    Ok(chunks)
}

fn wire_color(color: fyolod_vt::Color) -> WireColor {
    match color {
        fyolod_vt::Color::Default => WireColor::Default,
        fyolod_vt::Color::Palette(index) => WireColor::Palette(index),
        fyolod_vt::Color::Rgb(value) => WireColor::Rgb([value.r, value.g, value.b]),
    }
}

pub(crate) fn wire_cell(cell: fyolod_vt::Cell) -> WireCell {
    WireCell {
        codepoint: cell.codepoint,
        foreground: wire_color(cell.foreground),
        background: wire_color(cell.background),
        attributes: cell.attributes,
    }
}

pub(crate) fn grid_from_damage(frame_seq: u32, damage: fyolod_vt::Damage) -> GridDiff {
    GridDiff {
        frame_seq,
        rows: damage.rows,
        cols: damage.cols,
        cursor_x: damage.cursor_x,
        cursor_y: damage.cursor_y,
        alt_screen: damage.alt_screen,
        dirty_rows: damage
            .dirty_rows
            .into_iter()
            .map(|row| GridRow {
                row_index: row.row_index,
                cells: row.cells.into_iter().map(wire_cell).collect(),
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::{scrollback_row_limit, SCROLLBACK_STAGE_MAX_BYTES};
    use crate::protocol::SNAPSHOT_CELL_SIZE;

    #[test]
    fn scrollback_stage_cap_is_measured_in_encoded_rows() {
        let cols = 80u16;
        let row_bytes = usize::from(cols) * SNAPSHOT_CELL_SIZE;
        let rows = scrollback_row_limit(cols);

        assert!(rows * row_bytes <= SCROLLBACK_STAGE_MAX_BYTES);
        assert!((rows + 1) * row_bytes > SCROLLBACK_STAGE_MAX_BYTES);
    }
}
