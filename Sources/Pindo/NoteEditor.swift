import AppKit
import SwiftUI

/// Keeps the native text view and its input-method session alive across SwiftUI updates.
struct NoteEditor: NSViewRepresentable {
    @Environment(\.pindoLocalization) private var l10n
    @Binding var text: String
    var fontChoice = PindoFontChoice()
    var accessibilityName: String? = nil
    var onOutsideClick: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let view = ComposingTextView()
        view.isRichText = false; view.allowsUndo = true; view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.linkTextAttributes = [:]
        view.formatLocalization = l10n
        view.font = fontChoice.font(defaultSize: PindoFontPreferences.noteDefaultSize); view.textColor = .labelColor
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.string = text; view.delegate = context.coordinator
        view.setAccessibilityLabel(accessibilityName ?? l10n("待办备注内容"))
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
        if let view = scroll.documentView as? ComposingTextView {
            view.formatLocalization = l10n
            let label = accessibilityName ?? l10n("待办备注内容")
            if view.accessibilityLabel() != label { view.setAccessibilityLabel(label) }
            context.coordinator.synchronize(view, text: text)
        }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.removeOutsideMonitor() }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteEditor
        var isUpdating = false
        private var isStyling = false
        private var renderedSource: String?
        private var renderedParagraph: NSRange?
        private var renderedAppearance: String?
        private var renderedFont: PindoFontChoice?
        private var renderedFences: LiveMarkdown.Fences?
        private var outsideMonitor: Any?
        private var returning = false
        init(_ parent: NoteEditor) { self.parent = parent }
        func synchronize(_ view: NSTextView, text: String) {
            guard !view.hasMarkedText() else { return }
            if view.string != text {
                let range = view.selectedRange()
                isUpdating = true
                view.string = text
                // 整体替换文本时，旧段落上的样式也不再有效。
                renderedSource = nil
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
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            // 普通点按链接继续编辑，Command 点按才打开网页。
            if !textView.hasMarkedText(), charIndex <= (textView.string as NSString).length {
                textView.setSelectedRange(NSRange(location: charIndex, length: 0))
            }
            return true
        }
        func render(_ view: NSTextView) {
            guard !isUpdating, !isStyling, !view.hasMarkedText() else { return }
            let text = view.string
            let source = text as NSString
            let selection = view.selectedRange()
            let paragraph = source.paragraphRange(for: NSRange(location: min(selection.location, source.length), length: 0))
            let appearance = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue
            let textChanged = renderedSource.map { !$0.utf16.elementsEqual(text.utf16) } ?? true
            let fontChanged = renderedFont != parent.fontChoice
            guard textChanged || fontChanged || renderedParagraph != paragraph || renderedAppearance != appearance else { return }

            var ranges: [NSRange]?
            if !fontChanged, let previous = renderedSource, let previousParagraph = renderedParagraph, renderedAppearance == appearance {
                if textChanged {
                    ranges = affectedParagraphs(from: previous, to: text, previousParagraph: previousParagraph, editingParagraph: paragraph)
                } else {
                    ranges = [previousParagraph, paragraph]
                }
            }
            if textChanged || renderedFences == nil { renderedFences = LiveMarkdown.Fences(in: source) }
            isStyling = true
            LiveMarkdown.apply(to: view, editingParagraph: paragraph, fontChoice: parent.fontChoice, fences: renderedFences, ranges: ranges)
            isStyling = false
            renderedSource = text; renderedParagraph = paragraph; renderedAppearance = appearance
            renderedFont = parent.fontChoice
        }

        private func affectedParagraphs(from previous: String, to text: String, previousParagraph: NSRange,
                                        editingParagraph: NSRange) -> [NSRange]? {
            let before = Array(previous.utf16), after = Array(text.utf16)
            var start = 0, oldEnd = before.count, newEnd = after.count
            while start < min(oldEnd, newEnd), before[start] == after[start] { start += 1 }
            while oldEnd > start, newEnd > start, before[oldEnd - 1] == after[newEnd - 1] {
                oldEnd -= 1; newEnd -= 1
            }
            func coveringParagraphs(_ source: NSString, _ lower: Int, _ upper: Int) -> NSRange {
                NSUnionRange(source.paragraphRange(for: NSRange(location: lower, length: 0)),
                             source.paragraphRange(for: NSRange(location: upper, length: 0)))
            }
            let oldSource = previous as NSString, newSource = text as NSString
            let oldAffected = coveringParagraphs(oldSource, start, oldEnd)
            let newAffected = coveringParagraphs(newSource, start, newEnd)
            // 修改围栏标记可能改变后续段落的代码块归属，需要重排整份备注。
            if LiveMarkdown.Fences.mayContainFence(oldSource.substring(with: oldAffected) as NSString) ||
                LiveMarkdown.Fences.mayContainFence(newSource.substring(with: newAffected) as NSString) { return nil }

            func newOffset(_ oldOffset: Int) -> Int {
                if oldOffset <= start { return oldOffset }
                if oldOffset >= oldEnd { return oldOffset + newEnd - oldEnd }
                return newEnd
            }
            let lastInPrevious = max(previousParagraph.location, NSMaxRange(previousParagraph) - 1)
            let previousInNewText = coveringParagraphs(newSource, newOffset(previousParagraph.location),
                                                       newOffset(lastInPrevious))
            return [newAffected, previousInNewText, editingParagraph]
        }

        func installOutsideMonitor(_ scroll: NSScrollView) {
            guard parent.onOutsideClick != nil else { return }
            outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self, weak scroll] event in
                guard let self, let scroll, !self.returning, self.isOutsideEditor(event, scroll: scroll) else { return event }
                self.returning = true
                // Commit through this editor's window, before a settings action
                // can move keyboard focus into a different window.
                scroll.window?.makeFirstResponder(nil)
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
            var hit = content.hitTest(contentPoint)
            while let view = hit {
                if view is TaskTitleTextField { return false }
                hit = view.superview
            }
            // AppKit installs the title's shared field editor outside the field hierarchy.
            if let fieldEditor = content.hitTest(contentPoint) as? NSTextView,
               fieldEditor.isFieldEditor, (fieldEditor.delegate as AnyObject?) is TaskTitleTextField { return false }
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
    var formatLocalization = PindoLocalization(.automatic)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NoteDecoration.draw(in: self, dirtyRect: dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        if !hasMarkedText(), event.modifierFlags.contains(.command),
           let url = webLink(at: convert(event.locationInWindow, from: nil)) {
            NSWorkspace.shared.open(url)
        } else {
            super.mouseDown(with: event)
        }
    }

    func webLink(at point: NSPoint) -> URL? {
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs,
              layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(local) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < textStorage.length,
              let url = textStorage.attribute(.link, at: index, effectiveRange: nil) as? URL, LiveMarkdown.isOpenableLink(url)
        else { return nil }
        return url
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
        guard isEditable, !hasMarkedText() else { return menu }
        let label = formatLocalization("Markdown 格式")
        let formats = NSMenu(title: label)
        formats.autoenablesItems = false
        let selection = (string as NSString).substring(with: selectedRange())
        for format in NoteFormat.allCases {
            if format == .heading { formats.addItem(.separator()) }
            let item = NSMenuItem(title: formatLocalization(format.title), action: #selector(applyFormatMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.tag = format.rawValue
            item.isEnabled = format != .link || selection.rangeOfCharacter(from: .newlines) == nil
            formats.addItem(item)
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        item.submenu = formats
        menu.addItem(item)
        return menu
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, performFormattingShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !performFormattingShortcut(event) { super.keyDown(with: event) }
    }

    private func performFormattingShortcut(_ event: NSEvent) -> Bool {
        guard isEditable, !hasMarkedText(), event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
        else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b": applyFormat(.bold)
        case "i": applyFormat(.italic)
        default: return false
        }
        return true
    }

    override func unmarkText() { super.unmarkText(); didCommitText?() }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { didCommitText?() }
        return result
    }
}
