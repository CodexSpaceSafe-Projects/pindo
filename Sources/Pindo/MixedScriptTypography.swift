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
    @discardableResult static func apply(to text: NSMutableAttributedString, range: NSRange, ignoring composition: NSRange? = nil) -> Bool {
        guard range.length > 0 else { return false }
        // Compose the final attributes off the live storage. Restoring old kerns
        // and adding new ones must never expose an intermediate unspaced layout.
        let original = text.attributedSubstring(from: range)
        let styled = NSMutableAttributedString(attributedString: original)
        let whole = NSRange(location: 0, length: styled.length)
        // Clear only spacing owned by Pindo. Engine markers can carry negative
        // kerning to hide syntax; preserve those advances across restyles.
        styled.enumerateAttribute(appliedKern, in: whole) { value, run, _ in
            guard let applied = value as? NSNumber else { return }
            if let current = styled.attribute(.kern, at: run.location, effectiveRange: nil) as? NSNumber, current == applied {
                if let original = styled.attribute(originalKern, at: run.location, effectiveRange: nil) as? NSNumber {
                    styled.addAttribute(.kern, value: original, range: run)
                } else { styled.removeAttribute(.kern, range: run) }
            }
        }
        styled.removeAttribute(appliedKern, range: whole)
        styled.removeAttribute(originalKern, range: whole)
        var hidden: [NSRange] = [], verbatim: [NSRange] = []
        styled.enumerateAttribute(.font, in: whole) { value, range, _ in
            if let font = value as? NSFont, font.pointSize < 1 { hidden.append(range) }
        }
        // Pinyin is an input-method preview, not committed Western text. Keep
        // its native metrics rather than adding a new gap beside each preview.
        if let composition {
            let clipped = NSIntersectionRange(range, composition)
            if clipped.length > 0 {
                hidden.append(NSRange(location: clipped.location - range.location, length: clipped.length))
            }
        }
        styled.enumerateAttribute(.backgroundColor, in: whole) { value, range, _ in
            if value != nil { verbatim.append(range) }
        }
        for target in MixedScriptSpacing.kerningRanges(in: styled.string, hidden: hidden, verbatim: verbatim) {
            let font = styled.attribute(.font, at: target.location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 14)
            let base = styled.attribute(.kern, at: target.location, effectiveRange: nil)
            let value = (base as? NSNumber)?.doubleValue ?? 0
            let spaced = value + Double(font.pointSize) * MixedScriptSpacing.em
            styled.addAttributes([.kern: spaced, appliedKern: spaced, originalKern: base ?? NSNull()], range: target)
        }

        return applyDifferences(from: original, to: styled, in: text, offset: range.location)
    }

    /// Transfer final attributes without exposing intermediate font/spacing
    /// passes. A native IME's marked range is owned entirely by AppKit.
    @discardableResult static func applyDifferences(from original: NSAttributedString, to styled: NSAttributedString,
                                                    in text: NSMutableAttributedString, offset base: Int,
                                                    excluding marked: NSRange? = nil) -> Bool {
        let whole = NSRange(location: 0, length: styled.length)
        // Reapplying unchanged text is a true no-op, including invalidation.
        var offset = 0, changed = false
        while offset < whole.length {
            var oldRun = NSRange(), newRun = NSRange()
            let before = original.attributes(at: offset, effectiveRange: &oldRun)
            let after = styled.attributes(at: offset, effectiveRange: &newRun)
            let end = min(NSMaxRange(oldRun), NSMaxRange(newRun))
            if !NSDictionary(dictionary: before).isEqual(to: after) {
                let run = NSRange(location: base + offset, length: end - offset)
                var writable = [run]
                if let marked, NSIntersectionRange(run, marked).length > 0 {
                    writable = []
                    if run.location < marked.location {
                        writable.append(NSRange(location: run.location, length: marked.location - run.location))
                    }
                    if NSMaxRange(marked) < NSMaxRange(run) {
                        writable.append(NSRange(location: NSMaxRange(marked), length: NSMaxRange(run) - NSMaxRange(marked)))
                    }
                }
                for range in writable {
                    text.setAttributes(after, range: range)
                    changed = true
                }
            }
            offset = end
        }
        return changed
    }

    static func styleEditor(_ view: NSTextView) {
        guard !view.hasMarkedText(), let storage = view.textStorage else { return }
        let undo = view.undoManager
        let registering = undo?.isUndoRegistrationEnabled == true
        if registering { undo?.disableUndoRegistration() }
        storage.beginEditing()
        let whole = NSRange(location: 0, length: storage.length)
        apply(to: storage, range: whole)
        storage.endEditing()
        var typing = view.typingAttributes
        if typing[.kern] != nil || typing[appliedKern] != nil || typing[originalKern] != nil {
            typing.removeValue(forKey: .kern)
            typing.removeValue(forKey: appliedKern)
            typing.removeValue(forKey: originalKern)
            view.typingAttributes = typing
        }
        if registering { undo?.enableUndoRegistration() }
    }
}
