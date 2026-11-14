import AppKit
import SwiftUI

/// A stable native title field keeps IME composition out of the saved document.
struct TaskTitleEditor: NSViewRepresentable {
    @Environment(\.pindoLocalization) private var l10n
    @Binding var text: String
    var fontChoice = PindoFontChoice()
    var defaultSize = 20
    var variant: PindoFontChoice.Variant = .semibold
    var maximumLines = 2
    var placeholder = "事项内容"
    var allowsEmpty = false
    var bordered = false
    var isFocused: Binding<Bool>? = nil
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> TaskTitleTextField {
        let field = TaskTitleTextField()
        field.isEditable = true; field.isSelectable = true
        field.isBordered = bordered; field.isBezeled = bordered; field.drawsBackground = false
        field.focusRingType = .none
        field.maximumNumberOfLines = maximumLines
        field.lineBreakMode = maximumLines == 1 ? .byClipping : .byWordWrapping
        field.cell?.wraps = maximumLines != 1
        field.cell?.isScrollable = maximumLines == 1
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.stringValue = text
        updateNSView(field, context: context)
        return field
    }

    func updateNSView(_ field: TaskTitleTextField, context: Context) {
        context.coordinator.parent = self
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            let font = fontChoice.font(defaultSize: defaultSize, variant: variant)
            if field.font != font { field.font = font }
            if field.textColor != .labelColor { field.textColor = .labelColor }
        }
        field.placeholderString = l10n(placeholder)
        field.setAccessibilityLabel(l10n(placeholder))
        context.coordinator.synchronize(field)
        field.wantsFocus = isFocused?.wrappedValue == true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TaskTitleTextField, context: Context) -> NSSize? {
        guard let width = proposal.width, width.isFinite, let cell = nsView.cell else { return nil }
        let size = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
        return NSSize(width: width, height: max(26, size.height))
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TaskTitleEditor
        init(_ parent: TaskTitleEditor) { self.parent = parent }

        func synchronize(_ field: NSTextField) {
            // Saving or editing the note must not replace an active title draft.
            guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            if field.currentEditor() == nil {
                if field.stringValue != parent.text { field.stringValue = parent.text }
                field.attributedStringValue = MixedScriptTypography.attributed(field.stringValue, attributes: [
                    .font: field.font ?? parent.fontChoice.font(defaultSize: parent.defaultSize, variant: parent.variant),
                    .foregroundColor: field.textColor ?? NSColor.labelColor
                ])
            } else if let editor = field.currentEditor() as? NSTextView {
                MixedScriptTypography.styleEditor(editor)
            }
        }

        func publish(_ field: NSTextField) {
            guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true,
                  parent.allowsEmpty || !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
            synchronize(field)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField,
               let editor = field.currentEditor() as? NSTextView {
                editor.allowsUndo = true
                parent.isFocused?.wrappedValue = true
                MixedScriptTypography.styleEditor(editor)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { publish(field) }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            (field as? TaskTitleTextField)?.wantsFocus = false
            parent.isFocused?.wrappedValue = false
            publish(field)
            // An empty draft never replaces the last valid title.
            if field.stringValue != parent.text { field.stringValue = parent.text }
            synchronize(field)
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
final class TaskTitleTextField: NSTextField {
    var wantsFocus = false {
        didSet { if wantsFocus && !oldValue { focusIfNeeded() } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocus { focusIfNeeded() }
    }

    private func focusIfNeeded() {
        guard let window, currentEditor() == nil else { return }
        window.makeFirstResponder(self)
    }
}
