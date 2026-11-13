import AppKit
import SwiftUI

/// A stable native title field keeps IME composition out of the saved document.
struct TaskTitleEditor: NSViewRepresentable {
    @Environment(\.pindoLocalization) private var l10n
    @Binding var text: String
    var fontChoice = PindoFontChoice()
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> TaskTitleTextField {
        let field = TaskTitleTextField()
        field.isEditable = true; field.isSelectable = true
        field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .none
        field.maximumNumberOfLines = 2
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.stringValue = text
        updateNSView(field, context: context)
        return field
    }

    func updateNSView(_ field: TaskTitleTextField, context: Context) {
        context.coordinator.parent = self
        field.font = fontChoice.font(defaultSize: 20, variant: .semibold)
        field.textColor = .labelColor
        field.placeholderString = l10n("事项内容")
        field.setAccessibilityLabel(l10n("事项内容"))
        context.coordinator.synchronize(field)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TaskTitleTextField, context: Context) -> NSSize? {
        guard let width = proposal.width, let cell = nsView.cell else { return nil }
        let size = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
        return NSSize(width: width, height: max(26, size.height))
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TaskTitleEditor
        init(_ parent: TaskTitleEditor) { self.parent = parent }

        func synchronize(_ field: NSTextField) {
            // Saving or editing the note must not replace an active title draft.
            guard field.currentEditor() == nil, field.stringValue != parent.text else { return }
            field.stringValue = parent.text
        }

        func publish(_ field: NSTextField) {
            guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true,
                  !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField,
               let editor = field.currentEditor() as? NSTextView { editor.allowsUndo = true }
        }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { publish(field) }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            publish(field)
            // An empty draft never replaces the last valid title.
            if field.stringValue != parent.text { field.stringValue = parent.text }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
            control.window?.makeFirstResponder(nil)
            parent.onSubmit()
            return true
        }
    }
}

/// Identifies the title's full hit area to the note's outside-click monitor.
final class TaskTitleTextField: NSTextField {}
