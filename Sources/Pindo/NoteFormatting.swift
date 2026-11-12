import AppKit

enum NoteFormat: Int, CaseIterable {
    case bold, italic, strike, inlineCode, link
    case heading, quote, bullet, ordered, task, codeBlock

    var title: String {
        switch self {
        case .bold: "加粗"
        case .italic: "斜体"
        case .strike: "删除线"
        case .inlineCode: "行内代码"
        case .link: "插入链接"
        case .heading: "二级标题"
        case .quote: "引用"
        case .bullet: "项目列表"
        case .ordered: "编号列表"
        case .task: "任务列表"
        case .codeBlock: "代码块"
        }
    }

    struct Edit {
        let range: NSRange
        let replacement: String
        let selection: NSRange
    }

    func edit(in source: NSString, selection: NSRange) -> Edit? {
        guard selection.location != NSNotFound, NSMaxRange(selection) <= source.length else { return nil }
        let selected = source.substring(with: selection)
        let multiline = selected.rangeOfCharacter(from: .newlines) != nil
        switch self {
        case .bold: return emphasis("**", in: source, selection: selection, multiline: multiline)
        case .italic: return emphasis("*", in: source, selection: selection, multiline: multiline)
        case .strike: return emphasis("~~", in: source, selection: selection, multiline: multiline)
        case .inlineCode:
            if multiline { return block(in: source, selection: selection) }
            let delimiter = String(repeating: "`", count: max(1, longestBackticks(in: selected) + 1))
            let padding = selected.hasPrefix("`") || selected.hasSuffix("`") ||
                (selected.hasPrefix(" ") && selected.hasSuffix(" ") && selected.contains(where: { $0 != " " })) ? " " : ""
            return Edit(range: selection, replacement: delimiter + padding + selected + padding + delimiter,
                        selection: NSRange(location: selection.location + delimiter.count + padding.count, length: selection.length))
        case .link:
            guard !multiline else { return nil }
            if selected.isEmpty {
                return Edit(range: selection, replacement: "[]()", selection: NSRange(location: selection.location + 1, length: 0))
            }
            let label = selected.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            return Edit(range: selection, replacement: "[\(label)](https://)",
                        selection: NSRange(location: selection.location + (label as NSString).length + 3, length: 8))
        case .heading: return prefix("## ", in: source, selection: selection)
        case .quote: return prefix("> ", in: source, selection: selection)
        case .bullet: return prefix("- ", in: source, selection: selection)
        case .ordered: return prefix("1. ", in: source, selection: selection, numbered: true)
        case .task: return prefix("- [ ] ", in: source, selection: selection)
        case .codeBlock: return block(in: source, selection: selection)
        }
    }

    private func emphasis(_ marker: String, in source: NSString, selection: NSRange, multiline: Bool) -> Edit {
        if multiline {
            let text = source.substring(with: selection) as NSString
            var result = "", offset = 0
            while offset < text.length {
                var end = 0, contentEnd = 0
                text.getLineStart(nil, end: &end, contentsEnd: &contentEnd, for: NSRange(location: offset, length: 0))
                let range = NSRange(location: offset, length: contentEnd - offset)
                let line = text.substring(with: range)
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    let edit = emphasis(marker, in: line as NSString,
                                        selection: NSRange(location: 0, length: range.length), multiline: false)
                    result += (line as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
                } else {
                    result += line
                }
                result += text.substring(with: NSRange(location: contentEnd, length: end - contentEnd))
                offset = end
            }
            return Edit(range: selection, replacement: result,
                        selection: NSRange(location: selection.location, length: (result as NSString).length))
        }

        let text = source.substring(with: selection)
        let leading = (String(text.prefix { $0.isWhitespace }) as NSString).length
        let trailing = (String(text.reversed().prefix { $0.isWhitespace }) as NSString).length
        let body = NSRange(location: selection.location + leading, length: max(0, selection.length - leading - trailing))
        if selection.length > 0, body.length == 0 { return Edit(range: selection, replacement: text, selection: selection) }
        let width = marker.count
        let end = NSMaxRange(body)
        if body.length > 0, body.location >= width, end + width <= source.length,
           source.substring(with: NSRange(location: body.location - width, length: width)) == marker,
           source.substring(with: NSRange(location: end, length: width)) == marker {
            let range = NSRange(location: body.location - width, length: body.length + 2 * width)
            return Edit(range: range, replacement: source.substring(with: body),
                        selection: NSRange(location: range.location, length: body.length))
        }
        let value = source.substring(with: body)
        if body.length > 2 * width, value.hasPrefix(marker), value.hasSuffix(marker) {
            let inner = (value as NSString).substring(with: NSRange(location: width, length: body.length - 2 * width))
            if !inner.contains(marker) {
                return Edit(range: body, replacement: inner,
                            selection: NSRange(location: body.location, length: (inner as NSString).length))
            }
        }
        return Edit(range: body, replacement: marker + value + marker,
                    selection: NSRange(location: body.location + width, length: body.length))
    }

    private func prefix(_ marker: String, in source: NSString, selection: NSRange, numbered: Bool = false) -> Edit {
        if selection.length == 0 {
            let line = source.lineRange(for: selection)
            let original = source.substring(with: line)
            let removing = original.hasPrefix(marker)
            let width = marker.count
            return Edit(range: NSRange(location: line.location, length: removing ? width : 0),
                        replacement: removing ? "" : marker,
                        selection: NSRange(location: removing ? max(line.location, selection.location - width) : selection.location + width,
                                           length: 0))
        }
        let range = source.lineRange(for: selection)
        var result = "", offset = range.location, item = 1
        while offset < NSMaxRange(range) {
            let line = source.lineRange(for: NSRange(location: offset, length: 0))
            let text = source.substring(with: line)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result += text
            } else {
                let prefix = numbered ? "\(item). " : marker
                result += text.hasPrefix(prefix) ? text : prefix + text
                item += 1
            }
            offset = NSMaxRange(line)
        }
        return Edit(range: range, replacement: result,
                    selection: NSRange(location: range.location, length: (result as NSString).length))
    }

    private func block(in source: NSString, selection: NSRange) -> Edit {
        let range = source.lineRange(for: selection)
        let content = source.substring(with: range)
        let delimiter = String(repeating: "`", count: max(3, longestBackticks(in: content) + 1))
        let endsWithBreak = content.last?.isNewline == true
        let newline = content.contains("\r\n") ? "\r\n" : "\n"
        let replacement = delimiter + newline + content + (endsWithBreak ? "" : newline) + delimiter +
            (NSMaxRange(range) < source.length ? newline : "")
        return Edit(range: range, replacement: replacement,
                    selection: NSRange(location: selection.location + delimiter.count + newline.utf16.count, length: selection.length))
    }

    private func longestBackticks(in text: String) -> Int {
        var longest = 0, count = 0
        for character in text {
            count = character == "`" ? count + 1 : 0
            longest = max(longest, count)
        }
        return longest
    }
}

extension ComposingTextView {
    func applyFormat(_ format: NoteFormat) {
        let source = string as NSString
        guard isEditable, !hasMarkedText(), let edit = format.edit(in: source, selection: selectedRange()),
              source.substring(with: edit.range) != edit.replacement else { return }
        let length = source.length - edit.range.length + (edit.replacement as NSString).length
        breakUndoCoalescing()
        insertText(edit.replacement, replacementRange: edit.range)
        if (string as NSString).length == length, NSMaxRange(edit.selection) <= length {
            setSelectedRange(edit.selection)
        }
        breakUndoCoalescing()
    }

    @objc func applyFormatMenuItem(_ item: NSMenuItem) {
        if let format = NoteFormat(rawValue: item.tag) { applyFormat(format) }
    }
}
