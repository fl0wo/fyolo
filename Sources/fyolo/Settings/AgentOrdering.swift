import Foundation

/// What a drag or a Move Up *means* for an ordered list of agent ids.
///
/// Kept out of `AgentSettingsTab` because it is arithmetic, and arithmetic
/// inside a `View` is arithmetic nobody can test. The reordering it describes
/// was rebuilt by hand once already — `onMove` is only honoured by an editable
/// `List`, so moving the roster into a grouped `Form` silently stopped it — and
/// the replacement shipped with no test at all. That is the gap this closes:
/// the drag is the pleasant path and the menu is the one that cannot quietly
/// break, but neither is worth much if the arithmetic under both is wrong.
///
/// Every operation returns `nil` for "this changes nothing", so a row dropped on
/// itself or a Move Up at the top is not recorded as an edit.
enum AgentOrdering {
    /// Drops `draggedID` at `targetID`'s position, shifting the rest along.
    static func moving(_ draggedID: String, onto targetID: String, in ids: [String]) -> [String]? {
        guard draggedID != targetID,
              let from = ids.firstIndex(of: draggedID),
              let to = ids.firstIndex(of: targetID)
        else { return nil }
        var moved = ids
        moved.remove(at: from)
        moved.insert(draggedID, at: to)
        return moved
    }

    /// Swaps `id` with its neighbour `offset` places away. A swap rather than a
    /// re-insert because that is what "up one" means when you are looking at a
    /// list: the two rows trade places, and repeating it walks the row through
    /// the list one step at a time.
    static func moving(_ id: String, by offset: Int, in ids: [String]) -> [String]? {
        guard let from = ids.firstIndex(of: id) else { return nil }
        let to = from + offset
        guard ids.indices.contains(to), to != from else { return nil }
        var moved = ids
        moved.swapAt(from, to)
        return moved
    }
}
