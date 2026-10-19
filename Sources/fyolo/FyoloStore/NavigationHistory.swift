import AppKit

/// Where the user has been, as a browser keeps it: the places behind, the one on screen, and the
/// ones ahead after going back. Generic over the place so its rules can be tested without a store.
///
/// The rules are the ones every browser and IDE converged on: a new place drops whatever was
/// ahead; arriving where you already are is no step; and a place that no longer exists — a closed
/// session, a deleted file — is skipped on the way past rather than landed on.
struct NavigationHistory<Place: Equatable> {
    private(set) var back: [Place] = []
    private(set) var current: Place?
    private(set) var forward: [Place] = []
    /// Past this, the oldest places are forgotten. A history nobody walks this far back through
    /// costs memory for nothing.
    var limit = 100

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// Records arriving at `place`. The same place again only refreshes what it carries (a
    /// re-versioned remote file, a re-fetched issue), so it never becomes a step of its own.
    mutating func visit(_ place: Place) {
        guard let current else {
            self.current = place
            return
        }
        guard current != place else {
            self.current = place
            return
        }
        back.append(current)
        if back.count > limit { back.removeFirst(back.count - limit) }
        self.current = place
        forward.removeAll()
    }

    /// Replaces what the current place carries without making a step — the editor's caret line
    /// before a jump, or the place a step back actually landed on.
    mutating func replaceCurrent(_ place: Place) {
        current = place
    }

    /// Steps back to the nearest place `isLive` accepts, dropping dead ones on the way. `nil`
    /// when nothing behind is alive; the current place stays put then.
    mutating func goBack(where isLive: (Place) -> Bool) -> Place? {
        guard let found = Self.nearestLive(in: &back, other: current, isLive) else { return nil }
        if let current { forward.append(current) }
        current = found
        return found
    }

    mutating func goForward(where isLive: (Place) -> Bool) -> Place? {
        guard let found = Self.nearestLive(in: &forward, other: current, isLive) else { return nil }
        if let current { back.append(current) }
        current = found
        return found
    }

    /// Pops `stack` down to its nearest live place that is not `other`, dropping the rest.
    private static func nearestLive(
        in stack: inout [Place], other: Place?, _ isLive: (Place) -> Bool
    ) -> Place? {
        while let candidate = stack.popLast() {
            if isLive(candidate), candidate != other { return candidate }
        }
        return nil
    }
}

/// One place in fyolo: the session on screen, what the inspector beside it shows, and whether that
/// detail fills the window. Back and forward restore all of it, because that is what a click
/// changed — maximizing a file to read it is a step as much as opening it was.
///
/// Equality is about *where*, not about what the place carries: a diff whose sibling list was
/// refreshed, a remote file re-versioned by a save, an issue whose labels were re-fetched are all
/// still the place you were at.
struct NavigationPlace {
    var session: Session.ID?
    var tab: InspectorTab
    var file: URL?
    var line: Int?
    var readOnly = false
    /// The file's origin when it lives on another machine; `file` is then a staged copy that
    /// means nothing on its own, so the place reopens from the device instead.
    var remote: RemoteDocument?
    var diff: GitDiffRequest?
    var issue: IssueSummary?
    var run: WorkflowRunReference?
    /// The Linear pane's ticket page, when the Linear tab shows one.
    var linearTicket: String?
    /// The detail is blown up to fill the window.
    var maximized = false

    /// Whether this place still exists to be returned to.
    func isLive(sessionExists: (Session.ID) -> Bool) -> Bool {
        if let session, !sessionExists(session) { return false }
        if remote == nil, let file, !FileManager.default.fileExists(atPath: file.path) { return false }
        return true
    }
}

extension NavigationPlace: Equatable {
    static func == (lhs: NavigationPlace, rhs: NavigationPlace) -> Bool {
        lhs.session == rhs.session
            && lhs.tab == rhs.tab
            && lhs.fileIdentity == rhs.fileIdentity
            && lhs.line == rhs.line
            && lhs.diffIdentity == rhs.diffIdentity
            && lhs.issue?.url == rhs.issue?.url
            && lhs.issue?.identifier == rhs.issue?.identifier
            && lhs.run?.repository == rhs.run?.repository
            && lhs.run?.runID == rhs.run?.runID
            && lhs.linearTicket == rhs.linearTicket
            && lhs.maximized == rhs.maximized
    }

    private var fileIdentity: String? {
        if let remote { return remote.host + "\u{1f}" + remote.root + "\u{1f}" + remote.path }
        return file?.standardizedFileURL.path
    }

    private var diffIdentity: [String?]? {
        diff.map { [$0.repoRoot, $0.device.map { "\($0)" }, $0.change.path, $0.commit, $0.range] }
    }
}

/// Asks the Linear pane to show a ticket page (or its list, for `nil`) — how going back reaches a
/// page that lives in the pane's own model. Each request is new, so asking twice for the same
/// ticket still lands.
struct LinearPageRequest: Equatable {
    let id = UUID()
    let ticket: String?
}

extension FyoloStore {
    /// The place on screen now.
    func currentNavigationPlace() -> NavigationPlace {
        NavigationPlace(
            session: selectedSessionID,
            tab: inspectorTab,
            file: openFileURL,
            line: openFileLine,
            readOnly: openFileReadOnly,
            remote: openFileURL == nil ? nil : openFileRemote,
            diff: openDiff,
            issue: openIssueDetail,
            run: openWorkflowRun,
            linearTicket: inspectorTab == .linear ? linearTicket : nil,
            maximized: inspectorMaximized)
    }

    /// Records the place on screen once the current burst of changes settles. A session switch
    /// re-states the inspector, a tab switch clears the detail, an open replaces another: each is
    /// several property writes, and they are one step. Every navigation funnels here — the
    /// selection's `didSet`, `refreshDetailPresentation`, and the Linear pane — so no call site
    /// has to remember to.
    func scheduleNavigationRecord() {
        guard !navigationRecordScheduled else { return }
        navigationRecordScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.recordNavigation() }
        }
    }

    private func recordNavigation() {
        navigationRecordScheduled = false
        // A device file still crossing the network is not a place yet; its arrival records it.
        guard openingRemoteFile == nil else { return }
        let place = currentNavigationPlace()
        if isRestoringNavigation {
            // Wherever a step back landed is the current place, even if it came out a little
            // different from the record — and it must not count as a new step, or forward dies.
            isRestoringNavigation = false
            navigationHistory.replaceCurrent(place)
            return
        }
        navigationHistory.visit(place)
    }

    /// The Linear pane's page changed. Mirrored here because the page lives in the pane's model,
    /// which the store cannot see.
    func noteLinearTicket(_ ticket: String?) {
        guard linearTicket != ticket else { return }
        linearTicket = ticket
        scheduleNavigationRecord()
    }

    /// The editor is about to jump away from `line` of the open file: remember the line, so
    /// coming back lands where the jump started rather than where the file was opened.
    func noteEditorLine(_ line: Int) {
        guard var place = navigationHistory.current, place == currentNavigationPlace(),
              place.file != nil else { return }
        place.line = line
        navigationHistory.replaceCurrent(place)
    }

    func navigateBack() {
        flushPendingNavigationRecord()
        let exists: (Session.ID) -> Bool = { [weak self] in self?.session($0) != nil }
        guard let place = navigationHistory.goBack(where: { $0.isLive(sessionExists: exists) })
        else { return }
        restore(place)
    }

    func navigateForward() {
        flushPendingNavigationRecord()
        let exists: (Session.ID) -> Bool = { [weak self] in self?.session($0) != nil }
        guard let place = navigationHistory.goForward(where: { $0.isLive(sessionExists: exists) })
        else { return }
        restore(place)
    }

    /// A step pressed in the same beat as a click must step from the click's place, not from the
    /// one before it.
    private func flushPendingNavigationRecord() {
        guard navigationRecordScheduled else { return }
        recordNavigation()
    }

    private func restore(_ place: NavigationPlace) {
        isRestoringNavigation = true
        if let session = place.session, selectedSessionID != session {
            selectedSessionID = session
        }
        applyInspectorState(InspectorState(
            tab: place.tab,
            openFileURL: place.remote == nil ? place.file : nil,
            openFileLine: place.line,
            openFileReadOnly: place.readOnly,
            openDiff: place.diff,
            openIssueDetail: place.issue,
            openWorkflowRun: place.run,
            listCollapsed: inspectorListCollapsed))
        if place.tab == .linear {
            linearTicket = place.linearTicket
            linearPageRequest = LinearPageRequest(ticket: place.linearTicket)
        }
        if let remote = place.remote {
            openRemoteFile(
                path: remote.path, name: (remote.path as NSString).lastPathComponent,
                provider: remote.provider, host: remote.host, at: place.line)
        }
        // After the inspector state, which always lands docked (see `InspectorState`).
        if place.maximized != inspectorMaximized { inspectorMaximized = place.maximized }
        // Restoring re-states the detail without announcing it, which leaves a collapsed
        // inspector collapsed — right for a session switch, wrong for a step the user asked to see.
        if place.file != nil || place.diff != nil || place.issue != nil || place.run != nil {
            detailDidOpen.send()
        }
        scheduleNavigationRecord()
    }
}
