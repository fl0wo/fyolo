import Foundation

/// One block of the Session menu's roster: the rows under a single header.
struct SessionGroup {
    /// Which tier of the sidebar this block comes from. The menu draws a divider
    /// wherever the tier changes, so the loose sections and the real projects read
    /// apart the way they do in the column.
    enum Tier {
        case terminals, chats, project
    }

    /// The header: a section's name for a loose block, the project's for a project.
    let name: String
    /// The workspace the block belongs to, shown beside the header once there is
    /// more than one — a bare "Terminals" in a list with three of them says
    /// nothing about which one you are about to jump into.
    let workspace: String
    let tier: Tier
    let sessions: [Session]
}

/// Menu-bar session navigation: the Session menu's live roster and the ⌘⇧]/⌘⇧[
/// cycling verbs. Both read the same flattened order, so the menu's list and
/// what "next" means always agree.
extension FyoloStore {
    /// Every session in the app, grouped the way the sidebar groups it: for each
    /// workspace, its Terminals, then its Chats, then its projects in sidebar
    /// order; within a project the primary checkout's sessions precede each
    /// worktree's, mirroring the sidebar's nesting. Blocks with no sessions are
    /// skipped — the menu is a jump list, not a browser. (Sessions pointing at a
    /// worktree the project no longer records are dropped here exactly as the
    /// sidebar drops them.)
    ///
    /// It spans every workspace on purpose. A menu that only listed the current
    /// scope would hide an agent waiting on the user behind a switch they would
    /// have to think to make; the scope belongs to the panes, not to the roster.
    var sidebarSessionGroups: [SessionGroup] {
        var groups: [SessionGroup] = []
        for workspace in workspaces {
            if !workspace.terminals.isEmpty {
                groups.append(SessionGroup(name: localized("Terminals"), workspace: workspace.name,
                                           tier: .terminals, sessions: workspace.terminals))
            }
            if !workspace.chats.isEmpty {
                groups.append(SessionGroup(name: localized("Chats"), workspace: workspace.name,
                                           tier: .chats, sessions: workspace.chats))
            }
            for project in projects(inWorkspace: workspace.id) where !project.sessions.isEmpty {
                guard !project.worktrees.isEmpty else {
                    groups.append(SessionGroup(name: project.name, workspace: workspace.name,
                                               tier: .project, sessions: project.sessions))
                    continue
                }
                let primary = project.sessions.filter {
                    $0.worktreePath == nil || $0.worktreePath == project.path
                }
                let nested = project.worktrees.flatMap { worktree in
                    project.sessions.filter { $0.worktreePath == worktree.path }
                }
                groups.append(SessionGroup(name: project.name, workspace: workspace.name,
                                           tier: .project, sessions: primary + nested))
            }
        }
        return groups
    }

    /// Selects the session `offset` steps away in the flattened sidebar order,
    /// wrapping at both ends — tab cycling for sessions. With nothing selected
    /// (the welcome page) it lands on the first/last session instead.
    func selectAdjacentSession(_ offset: Int) {
        let sessions = sidebarSessionGroups.flatMap(\.sessions)
        guard !sessions.isEmpty else { return }
        let target: Session?
        if let current = selectedSessionID,
           let index = sessions.firstIndex(where: { $0.id == current }) {
            let count = sessions.count
            target = sessions[((index + offset) % count + count) % count]
        } else {
            target = offset >= 0 ? sessions.first : sessions.last
        }
        guard let target, target.id != selectedSessionID else { return }
        selectedSessionID = target.id
        markSeen(target.id)
    }
}
