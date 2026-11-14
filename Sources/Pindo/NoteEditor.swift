import AppKit
import SwiftUI
import MarkdownEngine

/// MarkdownEngine owns TextKit 2 and its delegate. Pindo owns document commits,
/// typography and the surrounding panel's interaction boundaries.
struct NoteEditor: NSViewRepresentable {
    @Environment(\.pindoLocalization) private var l10n
    @Binding var text: String
    var fontChoice = PindoFontChoice()
    var accessibilityName: String? = nil
    var onOutsideClick: (() -> Void)? = nil
    var localization: PindoLocalization { l10n }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NoteEditorHost {
        let host = NoteEditorHost(rootView: context.coordinator.editor())
        host.bridge = context.coordinator
        context.coordinator.host = host
        return host
    }

    func updateNSView(_ host: NoteEditorHost, context: Context) {
        let bridge = context.coordinator
        bridge.parent = self
        bridge.attach()
        bridge.synchronize()
    }

    static func dismantleNSView(_ host: NoteEditorHost, coordinator: Coordinator) {
        coordinator.stop()
        host.bridge = nil
    }

    @MainActor final class Coordinator: NSObject {
        var parent: NoteEditor
        var source: String
        weak var host: NoteEditorHost?
        private(set) weak var textView: NSTextView?
        let documentID = UUID().uuidString
        private var notifications: [NSObjectProtocol] = []
        private var eventMonitor: Any?
        private var applyingTypography = false
        private var typographyScheduled = false
        private var ended = false
        private var stopped = false
        private var returning = false

        init(_ parent: NoteEditor) { self.parent = parent; source = parent.text }

        func synchronize() {
            // External text/font updates wait for the input method to commit.
            guard textView?.hasMarkedText() != true else { return }
            source = parent.text
            host?.rootView = editor()
            textView?.setAccessibilityLabel(parent.accessibilityName ?? parent.localization("待办备注内容"))
            scheduleTypography()
        }

        func editor() -> NativeTextViewWrapper {
            let font = parent.fontChoice.font(defaultSize: PindoFontPreferences.noteDefaultSize)
            var config = MarkdownEditorConfiguration.default
            config.textInsets = TextInsets(horizontal: 14, vertical: 14)
            config.scrollers = .vertical
            config.overscroll.percent = 0.15
            config.spellChecking.automaticQuoteSubstitution = false
            config.spellChecking.automaticSpellingCorrection = false
            config.extensions = [StrikethroughExtension()]
            config.services.bus = formatBus
            return NativeTextViewWrapper(
                text: Binding(get: { [weak self] in self?.source ?? "" }, set: { [weak self] value in
                    guard let self, !self.stopped, self.textView?.hasMarkedText() != true,
                          !self.ended || value == self.source else { return }
                    self.source = value
                    if self.parent.text != value { self.parent.text = value }
                    self.scheduleTypography()
                }),
                configuration: config, fontName: font.fontName, fontSize: font.pointSize, documentId: documentID,
                onBuildContextMenu: { [weak self] menu, _ in self?.formatMenu(menu) ?? menu }
            )
        }

        func attach() {
            guard !stopped, textView == nil, let host, let view = Self.findTextView(in: host) else { return }
            textView = view
            view.setAccessibilityLabel(parent.accessibilityName ?? parent.l10n("待办备注内容"))
            let center = NotificationCenter.default
            notifications.append(center.addObserver(forName: NSText.didBeginEditingNotification, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.ended = false }
            })
            notifications.append(center.addObserver(forName: NSText.didEndEditingNotification, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.commit(); self?.ended = true }
            })
            notifications.append(center.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: view.textStorage, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleTypography() }
            })
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
                guard let self, let host = self.host, event.window === host.window else { return event }
                if event.type == .keyDown, event.window?.firstResponder === self.textView,
                   event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
                   let key = event.charactersIgnoringModifiers?.lowercased(), ["b", "i"].contains(key) {
                    guard self.textView?.hasMarkedText() != true else { return event }
                    self.applyFormat(key == "b" ? .bold : .italic)
                    return nil
                }
                if event.type == .leftMouseDown, self.parent.onOutsideClick != nil, !self.returning,
                   self.isOutsideEditor(event, scroll: host) {
                    self.returning = true
                    host.window?.makeFirstResponder(nil)
                    self.commit()
                    DispatchQueue.main.async { [weak self] in self?.parent.onOutsideClick?() }
                }
                return event
            }
            scheduleTypography()
        }

        static func findTextView(in root: NSView) -> NSTextView? {
            if let text = root as? NSTextView { return text }
            return root.subviews.lazy.compactMap { findTextView(in: $0) }.first
        }

        /// Closing a panel must publish storage form before AppModel.flush(),
        /// even when the engine's asynchronous binding callback is still queued.
        func commit() {
            guard !stopped, let textView, !textView.hasMarkedText() else { return }
            let metadata = WikiLinkService.makeDisplayState(from: source).metadata
            let value = WikiLinkService.makeStorageState(from: textView.string, existingMetadata: metadata,
                                                        textStorage: textView.textStorage).storage
            source = value
            if parent.text != value { parent.text = value }
        }

        func scheduleTypography() {
            guard !stopped, !applyingTypography, !typographyScheduled else { return }
            typographyScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.typographyScheduled = false
                self.applyTypography()
            }
        }

        func applyTypography() {
            guard !stopped, !applyingTypography, let view = textView, !view.hasMarkedText(), let storage = view.textStorage else { return }
            applyingTypography = true
            defer { applyingTypography = false }
            let undo = view.undoManager, registering = view.undoManager?.isUndoRegistrationEnabled == true
            if registering { undo?.disableUndoRegistration() }
            storage.beginEditing()
            let whole = NSRange(location: 0, length: storage.length)
            NoteTypography.applyFallback(to: storage, range: whole, choice: parent.fontChoice)
            MixedScriptTypography.apply(to: storage, range: whole)
            storage.enumerateAttribute(.link, in: whole) { value, range, _ in
                if let url = value as? URL, !["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    storage.removeAttribute(.link, range: range)
                }
            }
            storage.endEditing()
            if registering { undo?.enableUndoRegistration() }
        }

        func isOutsideEditor(_ event: NSEvent, scroll: NSView) -> Bool {
            guard let window = scroll.window, event.window === window, let content = window.contentView else { return false }
            let point = content.convert(event.locationInWindow, from: nil)
            guard content.bounds.insetBy(dx: 7, dy: 7).contains(point) else { return false }
            var hit = content.hitTest(point)
            while let view = hit {
                if view is TaskTitleTextField { return false }
                if let editor = view as? NSTextView, editor.isFieldEditor, (editor.delegate as AnyObject?) is TaskTitleTextField { return false }
                hit = view.superview
            }
            return !scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil))
        }

        func stop() {
            stopped = true
            notifications.forEach { NotificationCenter.default.removeObserver($0) }
            notifications.removeAll()
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            textView = nil
        }
    }
}

@MainActor final class NoteEditorHost: NSHostingView<NativeTextViewWrapper> {
    weak var bridge: NoteEditor.Coordinator?
    override func layout() { super.layout(); bridge?.attach() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); bridge?.attach() }
}
