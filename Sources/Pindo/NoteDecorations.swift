import AppKit

extension NSAttributedString.Key {
    static let noteDecoration = Self("Pindo.NoteDecoration")
}

enum NoteDecoration: Hashable {
    case divider, bullet, checkbox(Bool), quote(Int)

    @MainActor static func draw(in view: NSTextView, dirtyRect: NSRect) {
        guard let storage = view.textStorage, storage.length > 0,
              let layout = view.layoutManager, let container = view.textContainer else { return }
        let origin = view.textContainerOrigin
        let glyphs = layout.glyphRange(forBoundingRectWithoutAdditionalLayout: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y),
                                       in: container)
        guard glyphs.length > 0 else { return }
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard characters.location != NSNotFound, NSMaxRange(characters) <= storage.length else { return }
        storage.enumerateAttribute(.noteDecoration, in: characters) { value, range, _ in
            guard let decoration = value as? Self else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            let line = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let location = layout.location(forGlyphAt: glyphs.location)
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let x = origin.x + line.minX + location.x
            let y = origin.y + line.minY + location.y - (font?.capHeight ?? 10) / 2
            decoration.draw(x: x, y: y, line: line, origin: origin, layout: layout, glyphs: glyphs, container: container)
        }
    }

    @MainActor private func draw(x: CGFloat, y: CGFloat, line: NSRect, origin: NSPoint, layout: NSLayoutManager,
                                 glyphs: NSRange, container: NSTextContainer) {
        switch self {
        case .divider:
            NSColor.separatorColor.setFill()
            let inset = container.lineFragmentPadding
            NSBezierPath.fill(NSRect(x: origin.x + line.minX + inset, y: origin.y + line.midY,
                                     width: max(0, line.width - 2 * inset), height: 1))
        case .bullet:
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: x + 3, y: y - 2, width: 4, height: 4)).fill()
        case .checkbox(let checked):
            let size = min(12, line.height * 0.65)
            let box = NSRect(x: x + 1, y: y - size / 2, width: size, height: size)
            let frame = NSBezierPath(roundedRect: box, xRadius: 2.5, yRadius: 2.5)
            if checked {
                NSColor.controlAccentColor.setFill(); frame.fill()
                let mark = NSBezierPath()
                mark.move(to: NSPoint(x: box.minX + size * 0.22, y: box.minY + size * 0.51))
                mark.line(to: NSPoint(x: box.minX + size * 0.43, y: box.minY + size * 0.71))
                mark.line(to: NSPoint(x: box.minX + size * 0.78, y: box.minY + size * 0.30))
                mark.lineWidth = 1.4
                NSColor.white.setStroke(); mark.stroke()
            } else {
                NSColor.secondaryLabelColor.setStroke(); frame.stroke()
            }
        case .quote(let depth):
            let last = layout.lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
            NSColor.separatorColor.setFill()
            for index in 0..<depth {
                NSBezierPath.fill(NSRect(x: origin.x + container.lineFragmentPadding + CGFloat(index) * 10,
                                         y: origin.y + line.minY + 1, width: 2, height: max(0, last.maxY - line.minY - 2)))
            }
        }
    }
}
