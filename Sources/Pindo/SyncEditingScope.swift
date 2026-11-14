import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let syncEditingWindowWillHide = Notification.Name("com.pindo.syncEditingWindowWillHide")
}

/// Commit native composition before hiding or tearing down its owning window.
@MainActor func finishSyncWindowEditing(_ window: NSWindow) {
    let editor = window.firstResponder as? NSTextView
    if editor?.hasMarkedText() == true { editor?.unmarkText() }
    window.makeFirstResponder(nil)
}

/// Leases nest across windows. A task has one editable draft at a time, so an
/// unseen local IME draft cannot overwrite another window's committed note.
struct SyncEditingScope<Content: View>: View {
    @Environment(\.pindoLocalization) private var l10n
    @StateObject private var lease: SyncEditingLease
    let model: AppModel
    let taskID: UUID?
    let onUnavailable: () -> Void
    let content: Content

    @MainActor init(model: AppModel, taskID: UUID? = nil, onUnavailable: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        _lease = StateObject(wrappedValue: SyncEditingLease(model: model, taskID: taskID))
        self.model = model; self.taskID = taskID
        self.onUnavailable = onUnavailable
        self.content = content()
    }

    var body: some View {
        // Group distributes its background into the conditional branches. Keep
        // the native window observer mounted while readiness changes the child.
        ZStack {
            if lease.matches(model: model, taskID: taskID) && lease.isGranted { content }
            else if lease.matches(model: model, taskID: taskID) && lease.attempted {
                VStack(spacing: 14) {
                    Text(l10n("此事项已在其他窗口中编辑，请先完成那里的修改。"))
                    Button(l10n("返回"), action: onUnavailable)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .background(SyncEditingWindowObserver(lease: lease, model: model, taskID: taskID)
            .frame(width: 0, height: 0).allowsHitTesting(false))
    }
}

/// Native teardown may run while SwiftUI invalidates its graph. The resource
/// token lives outside State storage, and teardown never publishes to that graph.
@MainActor final class SyncEditingLease: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private weak var model: AppModel?
    private var taskID: UUID?
    private var token: UUID?
    private var owner: UUID?
    private var publicationScheduled = false
    private(set) var attempted = false
    var isGranted: Bool { token != nil }

    init(model: AppModel, taskID: UUID?) { self.model = model; self.taskID = taskID }

    func matches(model: AppModel, taskID: UUID?) -> Bool { self.model === model && self.taskID == taskID }
    func attach(_ owner: UUID, model: AppModel, taskID: UUID?) {
        if !matches(model: model, taskID: taskID) {
            releaseToken(); attempted = false
            self.model = model; self.taskID = taskID
        }
        self.owner = owner
        schedulePublication()
    }
    func owns(_ owner: UUID) -> Bool { self.owner == owner }

    func visibilityChanged(_ visible: Bool, owner: UUID) {
        guard owns(owner) else { return }
        if visible {
            guard token == nil else { return }
            token = model?.acquireSyncEditing(taskID: taskID); attempted = true
        } else {
            guard token != nil || attempted else { return }
            releaseToken(); attempted = false
        }
        schedulePublication()
    }

    private func schedulePublication() {
        guard !publicationScheduled else { return }
        publicationScheduled = true
        // A window notification can arrive during graph removal. Publish after
        // that stack to whichever mount is current, rather than dropping a
        // pending readiness change when the original mount has been replaced.
        // This callback only publishes state; it cannot revive an old lease.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publicationScheduled = false
            guard self.owner != nil else { return }
            self.objectWillChange.send()
        }
    }

    func detach(_ owner: UUID) {
        guard owns(owner) else { return }
        self.owner = nil
        releaseToken()
        attempted = false
    }

    private func releaseToken() {
        guard let token else { return }
        self.token = nil
        model?.releaseSyncEditing(token, deferNotifications: true)
    }
}

/// SwiftUI may cache an NSHostingView after orderOut. Window visibility owns
/// this lease independently of SwiftUI's onDisappear delivery.
struct SyncEditingWindowObserver: NSViewRepresentable {
    let lease: SyncEditingLease
    let model: AppModel
    let taskID: UUID?

    func makeNSView(context: Context) -> VisibilityView { VisibilityView() }
    func updateNSView(_ view: VisibilityView, context: Context) {
        view.bind(lease, model: model, taskID: taskID)
    }
    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) { view.finish() }

    @MainActor final class VisibilityView: NSView {
        private var lease: SyncEditingLease?
        private var owner = UUID()
        private var finished = false
        private var observation: NSKeyValueObservation?
        private var lastVisible: Bool?

        func bind(_ lease: SyncEditingLease, model: AppModel, taskID: UUID?) {
            if self.lease !== lease || finished || !lease.matches(model: model, taskID: taskID) {
                self.lease?.detach(owner)
                owner = UUID(); finished = false; lastVisible = nil
                self.lease = lease; lease.attach(owner, model: model, taskID: taskID)
                observeWindow()
            }
            scheduleReport()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeWindow()
            scheduleReport()
        }

        private func observeWindow() {
            observation?.invalidate(); observation = nil
            NotificationCenter.default.removeObserver(self)
            guard !finished else { return }
            if let window {
                observation = window.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
                    DispatchQueue.main.async { [weak self] in self?.scheduleReport() }
                }
                for name in [NSWindow.willCloseNotification, .syncEditingWindowWillHide] {
                    NotificationCenter.default.addObserver(self, selector: #selector(willHide(_:)), name: name, object: window)
                }
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged(_:)), name: name, object: window)
                }
            }
        }

        func scheduleReport() {
            let owner = self.owner
            DispatchQueue.main.async { [weak self] in self?.report(owner: owner) }
        }

        private func report(owner: UUID) {
            guard !finished, self.owner == owner, let lease, lease.owns(owner) else { return }
            // A minimized window still owns an unfinished draft.
            let visible = window.map { $0.isVisible || $0.isMiniaturized } ?? false
            if !visible, let window { finishSyncWindowEditing(window) }
            guard lastVisible != visible else { return }
            lastVisible = visible; lease.visibilityChanged(visible, owner: owner)
        }

        @objc private func willHide(_ notification: Notification) {
            guard !finished, let lease, lease.owns(owner) else { return }
            if let window { finishSyncWindowEditing(window) }
            lastVisible = false; lease.visibilityChanged(false, owner: owner)
        }

        @objc private func visibilityChanged(_ notification: Notification) { scheduleReport() }

        func finish() {
            guard !finished else { return }
            finished = true
            // No native editing or UI publication here: NSHostingView may be
            // deinitializing. Explicit window hide/close commits before teardown.
            lease?.detach(owner); lease = nil
            observation?.invalidate(); observation = nil
            NotificationCenter.default.removeObserver(self)
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
