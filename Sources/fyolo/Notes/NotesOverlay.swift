import AppKit
import Combine
import SwiftUI

/// Puts the notes page over the terminal and the inspector while
/// `FyoloStore.notesVisible` is on.
///
/// The page is a sibling laid *above* the split view, not a pane inside it: the
/// terminal surfaces under it keep their exact size, so no shell is resized
/// (and made to repaint) by opening or closing notes, and the inspector keeps
/// whatever it was showing. It starts at the terminal column's leading edge, so
/// the sidebar stays usable and follows that edge as the sidebar moves.
@MainActor
final class NotesOverlay {
    private let store: FyoloStore
    private let settings: AppSettings
    private weak var container: NSView?
    private weak var leadingView: NSView?
    private var host: NSView?
    private var model: NotesModel?
    private var observers: [AnyCancellable] = []

    init(store: FyoloStore, settings: AppSettings, container: NSView, leadingView: NSView) {
        self.store = store
        self.settings = settings
        self.container = container
        self.leadingView = leadingView
        observers = [
            store.$notesVisible.removeDuplicates().sink { [weak self] visible in
                if visible { self?.show() } else { self?.hide() }
            },
            store.$selectedSessionID.sink { [weak self] _ in
                // The new selection is set after this publishes; read it next turn.
                DispatchQueue.main.async { self?.followSelection() }
            },
            NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
                .sink { [weak self] _ in self?.model?.saveAll() },
        ]
    }

    func saveAll() {
        model?.saveAll()
    }

    private func followSelection() {
        guard store.notesVisible else { return }
        model?.show(store.selectedNoteScope)
    }

    private func show() {
        guard host == nil, let container, let leadingView else { return }
        let model = self.model ?? NotesModel(scope: store.selectedNoteScope)
        model.show(store.selectedNoteScope)
        self.model = model
        let page = NotesPage(model: model) { [weak store] in store?.notesVisible = false }
            .environmentObject(settings)
        let host = NSHostingView(rootView: page)
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        host.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            host.animator().alphaValue = 1
        }
        self.host = host
    }

    private func hide() {
        model?.saveAll()
        guard let host else { return }
        self.host = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            host.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { host.removeFromSuperview() }
        }
    }
}
