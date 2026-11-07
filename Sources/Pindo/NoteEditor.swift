import AppKit
import SwiftUI

/// Keeps the native text view and its input-method session alive across SwiftUI updates.
struct NoteEditor: NSViewRepresentable {
    @Binding var text: String
    var accessibilityName = "待办备注内容"
    var onOutsideClick: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let view = ComposingTextView()
        view.isRichText = false; view.allowsUndo = true; view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.font = .systemFont(ofSize: 14); view.textColor = .labelColor
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.string = text; view.delegate = context.coordinator
        view.setAccessibilityLabel(accessibilityName)
        view.didCommitText = { [weak coordinator = context.coordinator, weak view] in
            if let view { coordinator?.publish(view) }
        }
        scroll.documentView = view
        context.coordinator.render(view)
        context.coordinator.installOutsideMonitor(scroll)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let view = scroll.documentView as? ComposingTextView { context.coordinator.synchronize(view, text: text) }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.removeOutsideMonitor() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteEditor
        var isUpdating = false
        private var isStyling = false
        private var renderedSource: String?
        private var renderedParagraph: NSRange?
        private var renderedAppearance: String?
        private var outsideMonitor: Any?
        private var returning = false
        init(_ parent: NoteEditor) { self.parent = parent }
        func synchronize(_ view: NSTextView, text: String) {
            guard !view.hasMarkedText() else { return }
            if view.string != text {
                let range = view.selectedRange()
                isUpdating = true
                view.string = text
                let location = min(range.location, (text as NSString).length)
                view.setSelectedRange(NSRange(location: location, length: min(range.length, (text as NSString).length - location)))
                isUpdating = false
            }
            render(view)
        }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { publish(view) }
        }
        func publish(_ view: NSTextView) {
            guard !isUpdating, !isStyling, !view.hasMarkedText() else { return }
            if parent.text != view.string { parent.text = view.string }
            render(view)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            if let view = notification.object as? NSTextView { render(view) }
        }
        func render(_ view: NSTextView) {
            guard !isUpdating, !isStyling, !view.hasMarkedText() else { return }
            let source = view.string as NSString
            let selection = view.selectedRange()
            let paragraph = source.paragraphRange(for: NSRange(location: min(selection.location, source.length), length: 0))
            let appearance = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue
            guard renderedSource != view.string || renderedParagraph != paragraph || renderedAppearance != appearance else { return }
            isStyling = true
            LiveMarkdown.apply(to: view, editingParagraph: paragraph)
            isStyling = false
            renderedSource = view.string; renderedParagraph = paragraph; renderedAppearance = appearance
        }

        func installOutsideMonitor(_ scroll: NSScrollView) {
            guard parent.onOutsideClick != nil else { return }
            outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self, weak scroll] event in
                guard let self, let scroll, !self.returning, self.isOutsideEditor(event, scroll: scroll) else { return event }
                self.returning = true
                // Let AppKit finish the click/IME commit before removing the editor.
                DispatchQueue.main.async { [weak self] in self?.parent.onOutsideClick?() }
                return event
            }
        }
        func isOutsideEditor(_ event: NSEvent, scroll: NSScrollView) -> Bool {
            guard let window = scroll.window, event.window === window, let content = window.contentView else { return false }
            // Border drags resize the window without closing the note. Other windows
            // include input-method candidates, menus and popovers, so ignore them.
            let contentPoint = content.convert(event.locationInWindow, from: nil)
            guard content.bounds.insetBy(dx: 7, dy: 7).contains(contentPoint) else { return false }
            return !scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil))
        }
        func removeOutsideMonitor() {
            if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
            outsideMonitor = nil
        }
    }
}

final class ComposingTextView: NSTextView {
    var didCommitText: (() -> Void)?
    override func unmarkText() { super.unmarkText(); didCommitText?() }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { didCommitText?() }
        return result
    }
}
