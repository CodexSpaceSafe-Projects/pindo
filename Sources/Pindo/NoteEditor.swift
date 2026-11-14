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
        private var typographyFont: PindoFontChoice?
        private var undoCommitScheduled = false
        private var ended = false
        private var stopped = false
        private var returning = false
        private var linkMetadata: [WikiLinkService.RangeKey: WikiLinkService.LinkMetadata] = [:]

        init(_ parent: NoteEditor) { self.parent = parent; source = parent.text }

        func synchronize() {
            // External text/font updates wait for the input method to commit.
            guard textView?.hasMarkedText() != true else { return }
            source = parent.text
            host?.rootView = editor()
            textView?.setAccessibilityLabel(parent.accessibilityName ?? parent.localization("待办备注内容"))
            if typographyFont != parent.fontChoice { applyTypography() }
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
                    self?.acceptEngineText(value)
                }),
                configuration: config, fontName: font.fontName, fontSize: font.pointSize, documentId: documentID,
                onBuildContextMenu: { [weak self] menu, _ in self?.formatMenu(menu) ?? menu }
            )
        }

        func attach() {
            guard !stopped, textView == nil, let host, let view = Self.findTextView(in: host) else { return }
            textView = view
            linkMetadata = WikiLinkService.makeDisplayState(from: source).metadata
            view.setAccessibilityLabel(parent.accessibilityName ?? parent.l10n("待办备注内容"))
            let center = NotificationCenter.default
            notifications.append(center.addObserver(forName: NSText.didBeginEditingNotification, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.ended = false }
            })
            notifications.append(center.addObserver(forName: NSText.didEndEditingNotification, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.commit(); self?.ended = true }
            })
            notifications.append(center.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: view.textStorage, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    if let storage = notification.object as? NSTextStorage { self?.storageChanged(storage) }
                }
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
            applyTypography()
        }

        static func findTextView(in root: NSView) -> NSTextView? {
            if let text = root as? NSTextView, text.delegate is NativeTextViewCoordinator { return text }
            return root.subviews.lazy.compactMap { findTextView(in: $0) }.first
        }

        /// Closing a panel must publish storage form before AppModel.flush(),
        /// even when the engine's asynchronous binding callback is still queued.
        func commit() {
            guard !stopped, let textView, !textView.hasMarkedText() else { return }
            let state = WikiLinkService.makeStorageState(from: textView.string, existingMetadata: linkMetadata,
                                                        textStorage: textView.textStorage)
            linkMetadata = state.metadata
            source = state.storage
            if parent.text != source { parent.text = source }
        }

        private func acceptEngineText(_ value: String) {
            guard !stopped, textView?.hasMarkedText() != true, !ended || value == source else { return }
            let incoming = WikiLinkService.makeDisplayState(from: value)
            if let view = textView {
                // A newer native edit can precede an older queued binding write.
                guard incoming.display == view.string else { return }
                var metadata = incoming.metadata
                for (key, link) in linkMetadata where metadata[key]?.id == nil { metadata[key] = link }
                let resolved = WikiLinkService.makeStorageState(from: view.string, existingMetadata: metadata,
                                                                textStorage: view.textStorage)
                linkMetadata = resolved.metadata
                source = resolved.storage
            } else { source = value }
            // The input method can finish composition after its last storage
            // notification. Finish that paragraph synchronously on commit too.
            if let view = textView { applyTypography(in: view.selectedRange()) }
            if parent.text != source { parent.text = source }
        }

        private func storageChanged(_ storage: NSTextStorage) {
            guard !stopped, !applyingTypography, let view = textView else { return }
            if storage.editedMask.contains(.editedCharacters) {
                let edited = storage.editedRange, delta = storage.changeInLength
                let oldEnd = edited.location + max(0, edited.length - delta)
                var shifted: [WikiLinkService.RangeKey: WikiLinkService.LinkMetadata] = [:]
                for (key, link) in linkMetadata {
                    let range = NSRange(location: key.location, length: key.length)
                    if NSMaxRange(range) <= edited.location {
                        shifted[key] = link
                    } else if range.location >= oldEnd {
                        let moved = NSRange(location: range.location + delta, length: range.length)
                        if moved.location >= 0 { shifted[WikiLinkService.RangeKey(moved)] = link }
                    }
                    // Links intersecting a replacement are recovered from the
                    // engine's retained attributes or its authoritative callback.
                }
                linkMetadata = shifted
                if view.undoManager?.isUndoing == true || view.undoManager?.isRedoing == true {
                    scheduleUndoCommit()
                }
            }
            linkMetadata = WikiLinkService.makeStorageState(from: view.string, existingMetadata: linkMetadata,
                                                            textStorage: storage).metadata
            // didProcessEditing is still inside TextKit's editing transaction,
            // before layout consumers see the Markdown engine's new attributes.
            applyTypography(in: storage.editedRange)
        }

        private func scheduleUndoCommit() {
            guard !undoCommitScheduled else { return }
            undoCommitScheduled = true
            // Native undo can restore characters without the engine publishing
            // its binding. Commit after the undo group finishes; layout stays
            // synchronous in storageChanged and never waits for this callback.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.undoCommitScheduled = false
                self.commit()
            }
        }

        func applyTypography(in editedRange: NSRange? = nil) {
            guard !stopped, !applyingTypography, let view = textView, let storage = view.textStorage else { return }
            let composing = view.hasMarkedText()
            // External/full font updates still wait for composition to finish.
            // Engine restyles during setMarkedText, however, wipe attributes on
            // the whole paragraph. Repair committed text in that same pass,
            // without writing a single attribute inside the marked range.
            guard !composing || editedRange != nil else { return }
            let marked = composing ? view.markedRange() : nil
            if let marked, marked.location == NSNotFound || marked.length == 0 { return }
            applyingTypography = true
            defer { applyingTypography = false }
            let undo = view.undoManager, registering = view.undoManager?.isUndoRegistrationEnabled == true
            if registering { undo?.disableUndoRegistration() }
            let whole = NSRange(location: 0, length: storage.length)
            let scope: NSRange
            if let editedRange, editedRange.location != NSNotFound {
                let safe = NSIntersectionRange(whole, editedRange)
                scope = (storage.string as NSString).paragraphRange(for: safe)
            } else { scope = whole }
            let original = storage.attributedSubstring(from: scope)
            let styled = NSMutableAttributedString(attributedString: original)
            let local = NSRange(location: 0, length: styled.length)
            let choice = composing ? typographyFont ?? parent.fontChoice : parent.fontChoice
            NoteTypography.applyFallback(to: styled, range: local, choice: choice)
            MixedScriptTypography.apply(to: styled, range: local)
            styled.enumerateAttribute(.link, in: local) { value, range, _ in
                if let url = value as? URL, !["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    styled.removeAttribute(.link, range: range)
                }
            }
            storage.beginEditing()
            MixedScriptTypography.applyDifferences(from: original, to: styled, in: storage, offset: scope.location, excluding: marked)
            storage.endEditing()
            if registering { undo?.enableUndoRegistration() }
            if editedRange == nil { typographyFont = parent.fontChoice }
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
