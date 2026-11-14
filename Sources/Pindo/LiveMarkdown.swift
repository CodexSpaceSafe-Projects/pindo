import AppKit
import CoreText
import PindoCore

/// Source-preserving TextKit rendering: editing a paragraph reveals its syntax;
/// other paragraphs display their formatting. No HTML, network requests or text replacements.
enum LiveMarkdown {
    fileprivate struct RangeIndex {
        // 区间按位置排列且互不重叠。查询从二分定位开始，避免反复扫过前面的代码段。
        let ranges: [NSRange]

        private func firstEnding(after location: Int) -> Int {
            var low = 0, high = ranges.count
            while low < high {
                let middle = low + (high - low) / 2
                if NSMaxRange(ranges[middle]) <= location { low = middle + 1 } else { high = middle }
            }
            return low
        }

        func intersects(_ range: NSRange) -> Bool {
            let index = firstEnding(after: range.location)
            return index < ranges.count && ranges[index].location < NSMaxRange(range)
        }

        func intersections(with range: NSRange) -> [NSRange] {
            ranges[firstEnding(after: range.location)...]
                .prefix { $0.location < NSMaxRange(range) }
                .map { NSIntersectionRange($0, range) }
        }
    }

    struct Fences {
        fileprivate let blocks: RangeIndex
        fileprivate let markers: RangeIndex

        init(in source: NSString) {
            var blocks: [NSRange] = [], markers: [NSRange] = []
            if Self.mayContainFence(source) {
                var open: (start: Int, token: String)?
                var offset = 0
                while offset < source.length {
                    let range = source.lineRange(for: NSRange(location: offset, length: 0))
                    let line = source.substring(with: range).trimmingCharacters(in: .newlines)
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~"), let marker = trimmed.first {
                        let token = String(trimmed.prefix { $0 == marker })
                        let delimiter = NSRange(location: offset, length: (line as NSString).length)
                        if let current = open {
                            if marker == current.token.first && token.count >= current.token.count && trimmed == token {
                                blocks.append(NSRange(location: current.start, length: NSMaxRange(range) - current.start))
                                markers.append(delimiter)
                                open = nil
                            }
                        } else if marker != "`" || !trimmed.dropFirst(token.count).contains("`") {
                            // 反引号围栏的说明不能再含反引号，否则会吞掉行内代码和后续段落。
                            open = (offset, token)
                            markers.append(delimiter)
                        }
                    }
                    offset = NSMaxRange(range)
                }
                if let open { blocks.append(NSRange(location: open.start, length: source.length - open.start)) }
            }
            self.blocks = RangeIndex(ranges: blocks)
            self.markers = RangeIndex(ranges: markers)
        }

        static func mayContainFence(_ source: NSString) -> Bool {
            source.range(of: "```", options: .literal).location != NSNotFound ||
                source.range(of: "~~~", options: .literal).location != NSNotFound
        }
    }

    @MainActor static func apply(to view: NSTextView, editingParagraph: NSRange, fontChoice: PindoFontChoice,
                                 fences: Fences? = nil, ranges: [NSRange]? = nil) {
        guard !view.hasMarkedText(), let storage = view.textStorage else { return }
        let source = storage.string as NSString
        let whole = NSRange(location: 0, length: source.length)
        let fences = fences ?? Fences(in: source)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5; paragraph.paragraphSpacing = 6
        let baseFont = fontChoice.font(defaultSize: PindoFontPreferences.noteDefaultSize)
        let base: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        let undo = view.undoManager
        let registered = undo?.isUndoRegistrationEnabled == true
        if registered { undo?.disableUndoRegistration() }
        storage.beginEditing()
        var scopes: [NSRange] = []
        let restyled = ranges?.map { neighboringLines(of: $0, in: source) } ?? [whole]
        for range in restyled.sorted(by: { $0.location < $1.location }) where range.length > 0 {
            if let last = scopes.last, NSMaxRange(last) >= range.location {
                scopes[scopes.count - 1] = NSUnionRange(last, range)
            } else { scopes.append(range) }
        }
        let renderer = Renderer(storage: storage, source: source, editing: editingParagraph,
                                fences: fences, paragraph: paragraph, fontChoice: fontChoice, baseFont: baseFont)
        for scope in scopes {
            storage.setAttributes(base, range: scope)
            renderer.render(scope)
            MixedScriptTypography.apply(to: storage, range: scope)
        }
        storage.endEditing()
        view.typingAttributes = base
        if registered { undo?.enableUndoRegistration() }
        view.needsDisplay = true
    }

    private static func neighboringLines(of range: NSRange, in source: NSString) -> NSRange {
        guard range.length > 0 else { return range }
        // 下划线式标题依赖相邻行，删掉标记时上一行也要恢复普通样式。
        let start = range.location > 0 ? Line(at: range.location - 1, in: source).range.location : 0
        var end = NSMaxRange(range) < source.length ? NSMaxRange(Line(at: NSMaxRange(range), in: source).range) : source.length
        if end < source.length {
            let following = Line(at: end, in: source)
            if MarkdownLine(source.substring(with: following.body)).underlineLevel != nil {
                end = NSMaxRange(following.range)
            }
        }
        return NSRange(location: start, length: end - start)
    }

    private struct Line {
        let range: NSRange
        let body: NSRange

        init(at offset: Int, in source: NSString) {
            var start = 0, end = 0, contentEnd = 0
            source.getLineStart(&start, end: &end, contentsEnd: &contentEnd, for: NSRange(location: offset, length: 0))
            range = NSRange(location: start, length: end - start)
            body = NSRange(location: start, length: contentEnd - start)
        }

        func absolute(_ local: NSRange) -> NSRange {
            NSRange(location: body.location + local.location, length: local.length)
        }
    }

    @MainActor private struct Renderer {
        let storage: NSTextStorage
        let source: NSString
        let editing: NSRange
        let fences: Fences
        let paragraph: NSParagraphStyle
        let fontChoice: PindoFontChoice
        let baseFont: NSFont

        private static let inlineCharacters = CharacterSet(charactersIn: "`*_~[<\\&")
        private static let inlineOptions = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, appliesSourcePositionAttributes: true)

        private var codeFont: NSFont {
            fontChoice.font(defaultSize: PindoFontPreferences.noteDefaultSize, offset: -2, variant: .monospaced)
        }

        func render(_ scope: NSRange) {
            for range in fences.blocks.intersections(with: scope) {
                storage.addAttributes([.font: codeFont, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.08)],
                                      range: range)
            }
            for marker in fences.markers.intersections(with: scope) {
                syntax(marker, active: NSIntersectionRange(marker, editing).length > 0)
            }
            var offset = scope.location
            while offset < NSMaxRange(scope) {
                let line = Line(at: offset, in: source)
                render(line)
                resolveFallbackFonts(in: line.body)
                offset = NSMaxRange(line.range)
            }
        }

        private func resolveFallbackFonts(in range: NSRange) {
            guard fontChoice.fallbackFamily != nil, range.length > 0 else { return }
            // TextKit 可能跳过主字体不含的字符，即使 Core Text 已经选中了备用字体。
            // 把实际补字字体应用到对应范围，保留 Markdown 样式和原文。
            let line = CTLineCreateWithAttributedString(storage.attributedSubstring(from: range))
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let relative = CTRunGetStringRange(run)
                guard relative.location >= 0, relative.length > 0, relative.length <= range.length - relative.location,
                      let font = (CTRunGetAttributes(run) as NSDictionary)[NSAttributedString.Key.font] as? NSFont
                else { continue }
                let resolved = NSRange(location: range.location + relative.location, length: relative.length)
                guard let original = storage.attribute(.font, at: resolved.location, effectiveRange: nil) as? NSFont,
                      original.pointSize >= 1, original.fontName != font.fontName else { continue }
                storage.addAttribute(.font, value: font, range: resolved)
            }
        }

        private func render(_ line: Line) {
            guard !fences.blocks.intersects(line.range) else { return }
            let active = NSIntersectionRange(line.range, editing).length > 0

            let parsed = MarkdownLine(source.substring(with: line.body))
            if parsed.underlineLevel != nil, line.range.location > 0 {
                let previous = Line(at: line.range.location - 1, in: source)
                if setextLevel(after: previous) != nil {
                    syntax(line.body, active: active || NSIntersectionRange(previous.range, editing).length > 0)
                    return
                }
            }

            let content = line.absolute(parsed.content)
            let prefix = NSRange(location: line.body.location, length: parsed.content.location)
            switch parsed.kind {
            case .blank: return
            case .divider:
                if active {
                    syntax(line.body, active: true)
                } else {
                    storage.addAttribute(.foregroundColor, value: NSColor.clear, range: line.body)
                    storage.addAttribute(.noteDecoration, value: NoteDecoration.divider,
                                         range: NSRange(location: line.body.location, length: 1))
                }
                return
            case .heading(let level):
                heading(level, range: content)
                syntax(prefix, active: active)
                syntax(NSRange(location: NSMaxRange(content), length: NSMaxRange(line.body) - NSMaxRange(content)), active: active)
            case .quote(let depth):
                let depth = min(depth, 5)
                let style = indented(first: CGFloat(depth) * 10, rest: CGFloat(depth) * 10)
                storage.addAttributes([.paragraphStyle: style, .foregroundColor: NSColor.secondaryLabelColor], range: line.range)
                storage.addAttribute(.noteDecoration, value: NoteDecoration.quote(depth), range: line.body)
                syntax(prefix, active: active)
            case .list(let ordered, let checked):
                list(line, prefix: prefix, markerStart: parsed.markerStart, ordered: ordered, checked: checked, active: active)
            case .paragraph:
                if let level = setextLevel(after: line, parsed: parsed) {
                    heading(level, range: content)
                }
            }
            inlines(in: content, active: active)
        }

        private func setextLevel(after line: Line, parsed: MarkdownLine? = nil) -> Int? {
            guard !fences.blocks.intersects(line.range), NSMaxRange(line.range) < source.length else { return nil }
            let current = parsed ?? MarkdownLine(source.substring(with: line.body))
            guard current.kind == .paragraph, current.underlineLevel == nil else { return nil }
            let next = Line(at: NSMaxRange(line.range), in: source)
            guard let level = MarkdownLine(source.substring(with: next.body)).underlineLevel else { return nil }
            if line.range.location > 0 {
                let previous = Line(at: line.range.location - 1, in: source)
                if !fences.blocks.intersects(previous.range) {
                    let prior = MarkdownLine(source.substring(with: previous.body))
                    if prior.kind == .paragraph, prior.underlineLevel == nil { return nil }
                }
            }
            return level
        }

        private func heading(_ level: Int, range: NSRange) {
            let font = fontChoice.font(defaultSize: PindoFontPreferences.noteDefaultSize, offset: max(1, 12 - level * 2),
                                       variant: .semibold)
            storage.addAttribute(.font, value: font, range: range)
        }

        private func indented(first: CGFloat, rest: CGFloat) -> NSParagraphStyle {
            let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
            style.firstLineHeadIndent = first
            style.headIndent = rest
            return style
        }

        private func list(_ line: Line, prefix: NSRange, markerStart: Int, ordered: Bool, checked: Bool?, active: Bool) {
            let marker = NSRange(location: prefix.location + markerStart, length: 1)
            let indent = min(60, CGFloat(markerStart) * 5)
            let style: NSParagraphStyle
            if active {
                let rawWidth = (source.substring(with: prefix) as NSString).size(withAttributes: [.font: baseFont]).width
                style = indented(first: 0, rest: min(100, rawWidth))
                syntax(prefix, active: true)
            } else if ordered, checked == nil {
                syntax(NSRange(location: prefix.location, length: markerStart), active: false)
                let number = NSRange(location: marker.location, length: NSMaxRange(prefix) - marker.location)
                let width = (source.substring(with: number) as NSString).size(withAttributes: [.font: baseFont]).width
                style = indented(first: indent, rest: indent + width)
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: number)
            } else {
                let width = max(16, baseFont.pointSize + 5)
                style = indented(first: indent, rest: indent + width)
                syntax(prefix, active: false)
                let glyphWidth = (source.substring(with: marker) as NSString).size(withAttributes: [.font: baseFont]).width
                let decoration = checked.map(NoteDecoration.checkbox) ?? .bullet
                storage.addAttributes([.font: baseFont, .foregroundColor: NSColor.clear,
                                       .kern: max(0, width - glyphWidth), .noteDecoration: decoration], range: marker)
            }
            storage.addAttribute(.paragraphStyle, value: style, range: line.range)
        }

        private func syntax(_ range: NSRange, active: Bool) {
            guard range.length > 0 else { return }
            storage.removeAttribute(.link, range: range)
            if active {
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
            } else {
                // 保留原文的 UTF-16 位置，选区、输入法和撤销都由原生编辑器处理。
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.1), .foregroundColor: NSColor.clear], range: range)
            }
        }

        private struct Inline {
            let range: NSRange
            let intent: InlinePresentationIntent
            let link: URL?
            let image: Bool
        }

        private func inlines(in content: NSRange, active: Bool, insideLabel: Bool = false) {
            guard content.length > 0, source.rangeOfCharacter(from: Self.inlineCharacters, range: content).location != NSNotFound
            else { return }
            let raw = source.substring(with: content)
            guard let parsed = try? AttributedString(markdown: raw, options: Self.inlineOptions) else { return }
            var runs: [Inline] = []
            var end = content.location
            for run in parsed.runs {
                // 先核对所有范围，再隐藏间隙。系统解析器不能定位时整行保留原样。
                guard let position = run.markdownSourcePosition, let indices = Range(position, in: raw) else { return }
                let relative = NSRange(indices, in: raw)
                let range = NSRange(location: content.location + relative.location, length: relative.length)
                guard range.location >= end, range.length > 0, NSMaxRange(range) <= NSMaxRange(content) else { return }
                runs.append(Inline(range: range, intent: run.inlinePresentationIntent ?? [], link: run.link, image: run.imageURL != nil))
                end = NSMaxRange(range)
            }
            guard !runs.isEmpty else { return }

            end = content.location
            for run in runs {
                syntax(NSRange(location: end, length: run.range.location - end), active: active)
                style(run, active: active, insideLabel: insideLabel)
                end = NSMaxRange(run.range)
            }
            syntax(NSRange(location: end, length: NSMaxRange(content) - end), active: active)
        }

        private func style(_ run: Inline, active: Bool, insideLabel: Bool) {
            if run.intent.contains(.code) {
                storage.addAttributes([.font: codeFont, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.1)], range: run.range)
            } else {
                if run.intent.contains(.stronglyEmphasized) {
                    let font = storage.attribute(.font, at: run.range.location, effectiveRange: nil) as? NSFont ?? baseFont
                    storage.addAttribute(.font, value: fontChoice.applying(.boldFontMask, to: font), range: run.range)
                }
                if run.intent.contains(.emphasized) {
                    // 中文补字字体通常没有斜体字形，倾斜属性也能应用到补字。
                    storage.addAttribute(.obliqueness, value: 0.18, range: run.range)
                }
                if run.intent.contains(.strikethrough) {
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: run.range)
                }
                if !run.intent.contains(.inlineHTML) { escapes(in: run.range, active: active) }
            }
            guard !insideLabel, run.link != nil || run.image else { return }
            if run.image {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: run.range)
            } else if let link = run.link {
                storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue],
                                      range: run.range)
                if LiveMarkdown.isOpenableLink(link) { storage.addAttribute(.link, value: link, range: run.range) }
            }
            // 链接文字和图片说明中的强调也能渲染，地址本身不参与行内排版。
            inlines(in: run.range, active: active, insideLabel: true)
        }

        private func escapes(in range: NSRange, active: Bool) {
            var position = range.location
            while position + 1 < NSMaxRange(range) {
                if source.character(at: position) == 92 {
                    let next = source.character(at: position + 1)
                    if (33...47).contains(next) || (58...64).contains(next) || (91...96).contains(next) || (123...126).contains(next) {
                        syntax(NSRange(location: position, length: 1), active: active)
                        position += 1
                    }
                }
                position += 1
            }
        }
    }

    static func isOpenableLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        return url.host?.isEmpty == false
    }
}
