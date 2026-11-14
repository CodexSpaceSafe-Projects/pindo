import AppKit
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
    @ObservedObject var model: AppModel
    let taskID: UUID?
    let onUnavailable: () -> Void
    let content: Content
    @State private var token: UUID?
    @State private var attempted = false

    init(model: AppModel, taskID: UUID? = nil, onUnavailable: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.model = model; self.taskID = taskID; self.onUnavailable = onUnavailable
        self.content = content()
    }

    var body: some View {
        Group {
            if token != nil { content }
            else if attempted {
                VStack(spacing: 14) {
                    Text(l10n("此事项已在其他窗口中编辑，请先完成那里的修改。"))
                    Button(l10n("返回"), action: onUnavailable)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .background(SyncEditingWindowObserver { visible in
            if visible { acquire() } else { release() }
        }.frame(width: 0, height: 0).allowsHitTesting(false))
        .onAppear {
            acquire()
        }
        .onDisappear {
            release()
        }
    }

    private func acquire() {
        if token == nil { token = model.acquireSyncEditing(taskID: taskID); attempted = true }
    }

    private func release() {
        if let token { model.releaseSyncEditing(token); self.token = nil }
        attempted = false
    }
}

/// SwiftUI may cache an NSHostingView after orderOut. Window visibility owns
/// this lease independently of SwiftUI's onDisappear delivery.
private struct SyncEditingWindowObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView { VisibilityView() }
    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = onChange
        view.scheduleReport()
    }
    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) { view.finish() }

    @MainActor final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observation: NSKeyValueObservation?
        private var lastVisible: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation?.invalidate(); observation = nil
            NotificationCenter.default.removeObserver(self)
            if let window {
                observation = window.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
                    DispatchQueue.main.async { [weak self] in self?.report() }
                }
                for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification, .syncEditingWindowWillHide] {
                    NotificationCenter.default.addObserver(self, selector: #selector(willHide(_:)), name: name, object: window)
                }
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged(_:)), name: name, object: window)
                }
            }
            scheduleReport()
        }

        func scheduleReport() {
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report() {
            let visible = window.map { $0.isVisible && !$0.isMiniaturized } ?? false
            if !visible, let window { finishSyncWindowEditing(window) }
            guard lastVisible != visible else { return }
            lastVisible = visible; onChange?(visible)
        }

        @objc private func willHide(_ notification: Notification) {
            if let window { finishSyncWindowEditing(window) }
            lastVisible = false; onChange?(false)
        }

        @objc private func visibilityChanged(_ notification: Notification) { scheduleReport() }

        func finish() {
            if let window { finishSyncWindowEditing(window) }
            onChange?(false); onChange = nil
            observation?.invalidate(); observation = nil
            NotificationCenter.default.removeObserver(self)
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
