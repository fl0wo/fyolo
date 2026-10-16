import Foundation

/// Group by Task: the store's side of `TaskResolver` — gathering what the
/// resolver reads, stamping the anchors it relies on, and the manual moves.
extension FyoloStore {
    /// `sessions` arranged into tasks. The caller passes the rows it would draw,
    /// so the grouping never shows a session the plain tree would hide.
    func taskLayout(for project: Project, sessions: [Session]) -> TaskLayout {
        TaskResolver.layout(members: sessions.map { taskMember($0, in: project) })
    }

    private func taskMember(_ session: Session, in project: Project) -> TaskResolver.Member {
        let folder = session.worktreePath.flatMap { $0 == project.path ? nil : $0 }
        // A worktree is its own checkout, so its sessions are on whatever it has
        // out. The main checkout is shared by every session in it and switches
        // under them, so there the branch stamped when the session began counts —
        // the live one only for sessions older than the stamp.
        let branch = folder.flatMap(liveBranch(forFolder:))
            ?? session.taskAnchor?.branch
            ?? (folder == nil ? liveBranch(forFolder: project.path) : nil)
        return TaskResolver.Member(
            id: session.id,
            folder: folder,
            branch: branch,
            origin: session.taskAnchor?.origin,
            splitGroup: splitGroups.firstIndex { $0.contains(session.id) },
            mentionedTickets: session.taskAnchor?.mentionedTickets ?? [],
            override: session.taskOverride)
    }

    /// The branch a folder has out, or `nil` when it has none to give — not a
    /// repo, not resolved yet, or a detached HEAD, whose label is a commit.
    func liveBranch(forFolder folder: String) -> String? {
        guard !isDetachedHead(forFolder: folder), let branch = branch(forFolder: folder),
              branch != "—"
        else { return nil }
        return branch
    }

    /// The anchor a new session starts with: the branch its checkout has out,
    /// and the session it was opened from.
    func taskAnchor(checkout: String?, origin: Session.ID?) -> TaskAnchor {
        TaskAnchor(branch: checkout.flatMap(liveBranch(forFolder:)), origin: origin)
    }

    /// An agent's prompt is when its work starts, so it is when the anchor learns
    /// the tickets the prompt names and, for a session in the main checkout that
    /// was opened on trunk before its branch was made, which branch it is on.
    /// Each is learned once: a row moves when it first learns its task, never
    /// because a later prompt or checkout said something else.
    func recordTaskPrompt(_ raw: String, for id: Session.ID) {
        guard let session = session(id), session.agent != .terminal,
              case .project(let projectIndex, _)? = locate(id)
        else { return }
        let project = projects[projectIndex]
        var anchor = session.taskAnchor ?? TaskAnchor()
        if anchor.mentionedTickets.isEmpty {
            anchor.mentionedTickets = TaskTicketPattern().identifiers(inText: raw)
        }
        let inMainCheckout = session.worktreePath == nil || session.worktreePath == project.path
        if inMainCheckout,
           anchor.branch.map(TaskResolver.trunkBranches.contains) ?? true,
           let branch = liveBranch(forFolder: project.path) {
            anchor.branch = branch
        }
        guard anchor != session.taskAnchor else { return }
        updateSession(id) { $0.taskAnchor = anchor }
    }

    /// The checkout a session runs in — its worktree, else its project's folder —
    /// or `nil` for a loose session, which has no checkout to read a branch from.
    func checkoutFolder(of id: Session.ID) -> String? {
        guard case .project(let projectIndex, _)? = locate(id) else { return nil }
        return session(id)?.worktreePath ?? projects[projectIndex].path
    }

    /// Files a session under `task` by hand. Its own evidence stops counting, so
    /// it stays there whatever its branch says.
    func moveSession(_ id: Session.ID, toTask task: TaskGroup.ID) {
        updateSession(id) { $0.taskOverride = .task(task) }
    }

    /// Keeps a session out of every task.
    func removeSessionFromTask(_ id: Session.ID) {
        updateSession(id) { $0.taskOverride = .excluded }
    }

    /// Hands a session moved by hand back to the automatic grouping.
    func groupSessionAutomatically(_ id: Session.ID) {
        updateSession(id) { $0.taskOverride = nil }
    }

    /// Starts a session inside `task`: in its worktree when it has exactly one,
    /// and filed under it either way, since a session started from a task's own
    /// row was put there by the user.
    func addSession(to project: Project.ID, agent: AgentPreset, inTask task: TaskGroup) {
        let folder = task.folders.count == 1 ? task.folders.first : nil
        guard let id = addSession(to: project, agent: agent, worktreePath: folder) else { return }
        moveSession(id, toTask: task.id)
    }
}
