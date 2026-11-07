import AppKit
import SwiftUI

/// Keeps the native text view and its input-method session alive across SwiftUI updates.
struct NoteEditor: NSViewRepresentable {
    @Binding var text: String
    var accessibilityName = "待办备注内容"

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let view = ComposingTextView()
        view.isRichText = false; view.allowsUndo = true; view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.font = .systemFont(ofSize: 13); view.textColor = .labelColor
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.string = text; view.delegate = context.coordinator
        view.setAccessibilityLabel(accessibilityName)
        view.didCommitText = { [weak coordinator = context.coordinator, weak view] in
            if let view { coordinator?.publish(view) }
        }
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let view = scroll.documentView as? ComposingTextView { context.coordinator.synchronize(view, text: text) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteEditor
        var isUpdating = false
        init(_ parent: NoteEditor) { self.parent = parent }
        func synchronize(_ view: NSTextView, text: String) {
            guard !view.hasMarkedText(), view.string != text else { return }
            let range = view.selectedRange()
            isUpdating = true
            view.string = text
            let location = min(range.location, (text as NSString).length)
            view.setSelectedRange(NSRange(location: location, length: 0))
            isUpdating = false
        }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { publish(view) }
        }
        func publish(_ view: NSTextView) {
            guard !isUpdating, !view.hasMarkedText(), parent.text != view.string else { return }
            parent.text = view.string
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
