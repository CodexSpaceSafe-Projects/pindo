import AppKit
import CoreText

@MainActor enum NoteTypography {
    static func applyFonts(to storage: NSMutableAttributedString, range: NSRange, choice: PindoFontChoice,
                           composition: NSRange? = nil) {
        guard range.length > 0, choice.primaryFamily != nil || choice.fallbackFamily != nil else { return }
        let configured = choice.font(defaultSize: PindoFontPreferences.noteDefaultSize)
        storage.enumerateAttributes(in: range) { attributes, run, _ in
            guard let font = attributes[.font] as? NSFont, font.pointSize >= 1 else { return }
            let manager = NSFontManager.shared
            let traits = manager.traits(of: font).intersection([.boldFontMask, .italicFontMask])
            // AppKit/attributed IME input can leave a system CJK font here. It
            // already contains Han glyphs, so merely adding a fallback to THAT
            // font can never restore the user's preferred Chinese face.
            // Resolve prose from the configured primary again; preserve the
            // engine's heading size/traits and its dedicated code fonts.
            let inComposition = composition.map { NSIntersectionRange($0, run).length > 0 } ?? false
            // An IME's selected-clause background is not an inline code span.
            let code = (!inComposition && attributes[.backgroundColor] != nil && (attributes[.spellingState] as? Int) == 0)
                || (font.isFixedPitch && font.familyName != configured.familyName)
            let base = code ? font : NSFont(descriptor: configured.fontDescriptor, size: font.pointSize) ?? configured
            let preferred = choice.applying(traits, to: base)
            let fragment = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: run))
            fragment.addAttribute(.font, value: preferred, range: NSRange(location: 0, length: fragment.length))
            let line = CTLineCreateWithAttributedString(fragment)
            for item in CTLineGetGlyphRuns(line) as! [CTRun] {
                let local = CTRunGetStringRange(item)
                guard let resolved = (CTRunGetAttributes(item) as NSDictionary)[NSAttributedString.Key.font] as? NSFont else { continue }
                let target = NSRange(location: run.location + local.location, length: local.length)
                if resolved.fontName != font.fontName || resolved.pointSize != font.pointSize {
                    storage.addAttribute(.font, value: resolved, range: target)
                }
            }
        }
    }
}
