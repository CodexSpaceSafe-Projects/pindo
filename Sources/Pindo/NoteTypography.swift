import AppKit
import CoreText

@MainActor enum NoteTypography {
    static func applyFallback(to storage: NSTextStorage, range: NSRange, choice: PindoFontChoice) {
        guard let family = choice.fallbackFamily, range.length > 0 else { return }
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            guard let font = value as? NSFont, font.pointSize >= 1 else { return }
            let manager = NSFontManager.shared
            let traits = manager.traits(of: font).intersection([.boldFontMask, .italicFontMask])
            guard let fallback = manager.font(withFamily: family, traits: traits, weight: manager.weight(of: font), size: font.pointSize)
                ?? manager.font(withFamily: family, traits: [], weight: 5, size: font.pointSize) else { return }
            let descriptor = font.fontDescriptor.addingAttributes([.cascadeList: [fallback.fontDescriptor]])
            let preferred = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
            let fragment = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: run))
            fragment.addAttribute(.font, value: preferred, range: NSRange(location: 0, length: fragment.length))
            let line = CTLineCreateWithAttributedString(fragment)
            for item in CTLineGetGlyphRuns(line) as! [CTRun] {
                let local = CTRunGetStringRange(item)
                guard let resolved = (CTRunGetAttributes(item) as NSDictionary)[NSAttributedString.Key.font] as? NSFont else { continue }
                let target = NSRange(location: run.location + local.location, length: local.length)
                if resolved.fontName != font.fontName { storage.addAttribute(.font, value: resolved, range: target) }
            }
        }
    }
}
