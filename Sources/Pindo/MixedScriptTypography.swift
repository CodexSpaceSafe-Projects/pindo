import AppKit
import PindoCore

@MainActor enum MixedScriptTypography {
    private static let appliedKern = NSAttributedString.Key("Pindo.MixedScriptAppliedKern")
    private static let originalKern = NSAttributedString.Key("Pindo.MixedScriptOriginalKern")
    static func attributed(_ text: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        apply(to: result, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// Run after Markdown styling so hidden delimiters do not interrupt visible
    /// script boundaries. Code retains its fixed character advances.
    static func apply(to text: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        // Clear only spacing owned by Pindo. Engine markers can carry negative
        // kerning to hide syntax; preserve those advances across restyles.
        text.enumerateAttribute(appliedKern, in: range) { value, run, _ in
            guard let applied = value as? NSNumber else { return }
            if let current = text.attribute(.kern, at: run.location, effectiveRange: nil) as? NSNumber, current == applied {
                if let original = text.attribute(originalKern, at: run.location, effectiveRange: nil) as? NSNumber {
                    text.addAttribute(.kern, value: original, range: run)
                } else { text.removeAttribute(.kern, range: run) }
            }
        }
        text.removeAttribute(appliedKern, range: range)
        text.removeAttribute(originalKern, range: range)
        let fragment = text.attributedSubstring(from: range)
        let whole = NSRange(location: 0, length: fragment.length)
        var hidden: [NSRange] = [], verbatim: [NSRange] = []
        fragment.enumerateAttribute(.font, in: whole) { value, range, _ in
            if let font = value as? NSFont, font.pointSize < 1 { hidden.append(range) }
        }
        fragment.enumerateAttribute(.backgroundColor, in: whole) { value, range, _ in
            if value != nil { verbatim.append(range) }
        }
        for local in MixedScriptSpacing.kerningRanges(in: fragment.string, hidden: hidden, verbatim: verbatim) {
            let target = NSRange(location: range.location + local.location, length: local.length)
            let font = text.attribute(.font, at: target.location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 14)
            let original = text.attribute(.kern, at: target.location, effectiveRange: nil)
            let value = (original as? NSNumber)?.doubleValue ?? 0
            let spaced = value + Double(font.pointSize) * MixedScriptSpacing.em
            text.addAttributes([.kern: spaced, appliedKern: spaced, originalKern: original ?? NSNull()], range: target)
        }
    }

    static func styleEditor(_ view: NSTextView) {
        guard !view.hasMarkedText(), let storage = view.textStorage else { return }
        let undo = view.undoManager
        let registering = undo?.isUndoRegistrationEnabled == true
        if registering { undo?.disableUndoRegistration() }
        storage.beginEditing()
        let whole = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.kern, range: whole)
        apply(to: storage, range: whole)
        storage.endEditing()
        view.typingAttributes.removeValue(forKey: .kern)
        if registering { undo?.enableUndoRegistration() }
    }
}
