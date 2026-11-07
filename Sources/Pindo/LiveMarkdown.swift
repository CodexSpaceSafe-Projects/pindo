import AppKit

/// Source-preserving TextKit rendering: editing a paragraph reveals its syntax;
/// other paragraphs display their formatting. No HTML, network requests or text replacements.
enum LiveMarkdown {
    static func apply(to view: NSTextView, editingParagraph: NSRange) {
        guard !view.hasMarkedText(), let storage = view.textStorage else { return }
        let source = storage.string as NSString
        let whole = NSRange(location: 0, length: source.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5; paragraph.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        let undo = view.undoManager
        let registered = undo?.isUndoRegistrationEnabled == true
        if registered { undo?.disableUndoRegistration() }
        storage.beginEditing()
        storage.setAttributes(base, range: whole)
        var codeRanges: [NSRange] = []
        var fenceRanges: [NSRange] = []
        var fenceStart: Int?
        var fenceToken = ""
        var offset = 0
        while offset < source.length {
            let range = source.lineRange(for: NSRange(location: offset, length: 0))
            let line = source.substring(with: range).trimmingCharacters(in: .newlines)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let token = String(trimmed.prefix(while: { $0 == trimmed.first! }))
                if fenceStart == nil { fenceStart = offset; fenceToken = token; fenceRanges.append(NSRange(location: offset, length: (line as NSString).length)) }
                else if token.first == fenceToken.first && token.count >= fenceToken.count && trimmed == token {
                    codeRanges.append(NSRange(location: fenceStart!, length: NSMaxRange(range) - fenceStart!)); fenceStart = nil
                    fenceRanges.append(NSRange(location: offset, length: (line as NSString).length))
                }
            }
            offset = NSMaxRange(range)
        }
        if let fenceStart { codeRanges.append(NSRange(location: fenceStart, length: source.length - fenceStart)) }
        func inCode(_ range: NSRange) -> Bool { codeRanges.contains { NSIntersectionRange($0, range).length > 0 } }
        func matches(_ pattern: String) -> [NSTextCheckingResult] {
            (try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]).matches(in: source as String, range: whole)) ?? []
        }
        func syntax(_ range: NSRange) {
            guard range.location != NSNotFound, range.length > 0 else { return }
            if NSIntersectionRange(range, editingParagraph).length > 0 {
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
            } else {
                // Keep UTF-16 positions intact for selection, copy, undo and IME.
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.1), .foregroundColor: NSColor.clear], range: range)
            }
        }
        for range in codeRanges {
            storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.08)], range: range)
        }
        for range in fenceRanges { syntax(range) }
        for match in matches("^ {0,3}(#{1,6})[ \\t]+(.+)$") where !inCode(match.range) {
            let level = match.range(at: 1).length
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: CGFloat(max(15, 26 - level * 2)), weight: .semibold), range: match.range(at: 2))
            syntax(NSRange(location: match.range.location, length: match.range(at: 2).location - match.range.location))
        }
        for match in matches("^([ \\t]*>[ \\t]?)(.+)$") where !inCode(match.range) {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range)
            let quote = paragraph.mutableCopy() as! NSMutableParagraphStyle
            quote.headIndent = 12; quote.firstLineHeadIndent = 12
            storage.addAttribute(.paragraphStyle, value: quote, range: match.range)
            syntax(match.range(at: 1))
        }
        for match in matches("(?<!`)`([^`\\r\\n]+)`(?!`)") where !inCode(match.range) {
            storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.1)], range: match.range(at: 1))
            syntax(NSRange(location: match.range.location, length: 1)); syntax(NSRange(location: NSMaxRange(match.range) - 1, length: 1))
            codeRanges.append(match.range)
        }
        for (pattern, trait, width) in [
            ("(?<!\\\\)\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*", NSFontTraitMask.boldFontMask, 2),
            ("(?<!\\\\)__(?=\\S)(.+?)(?<=\\S)__", NSFontTraitMask.boldFontMask, 2),
            ("(?<![\\\\*])\\*(?!\\*)(?=\\S)(.+?)(?<=\\S)\\*(?!\\*)", NSFontTraitMask.italicFontMask, 1),
            ("(?<![\\\\_])_(?!_)(?=\\S)(.+?)(?<=\\S)_(?!_)", NSFontTraitMask.italicFontMask, 1)
        ] {
            for match in matches(pattern) where !inCode(match.range) {
                let content = match.range(at: 1)
                storage.enumerateAttribute(.font, in: content) { value, range, _ in
                    let font = value as? NSFont ?? .systemFont(ofSize: 14)
                    storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: range)
                }
                syntax(NSRange(location: match.range.location, length: width)); syntax(NSRange(location: NSMaxRange(match.range) - width, length: width))
            }
        }
        for match in matches("~~(?=\\S)(.+?)(?<=\\S)~~") where !inCode(match.range) {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: match.range(at: 1))
            syntax(NSRange(location: match.range.location, length: 2)); syntax(NSRange(location: NSMaxRange(match.range) - 2, length: 2))
        }
        for match in matches("(?<!!)\\[([^]\\r\\n]+)\\]\\(([^)\\s]+)\\)") where !inCode(match.range) {
            storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range(at: 1))
            syntax(NSRange(location: match.range.location, length: 1))
            syntax(NSRange(location: NSMaxRange(match.range(at: 1)), length: NSMaxRange(match.range) - NSMaxRange(match.range(at: 1))))
        }
        for match in matches("^[ \\t]*(?:[-+*]|[0-9]+\\.)[ \\t]+(?:\\[[ xX]\\][ \\t]+)?") where !inCode(match.range) {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range)
        }
        storage.endEditing()
        view.typingAttributes = base
        if registered { undo?.enableUndoRegistration() }
    }
}
