import Foundation

public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case quote(String)
    case listItem(text: String, checked: Bool?)
    case code(language: String, text: String)
    case divider
}

public enum NoteMarkdown {
    /// A small, local-only block parser. Inline emphasis and links are rendered by the OS.
    public static func blocks(_ source: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = [], paragraph: [String] = [], code: [String] = []
        var language: String?, fence: String?
        func flushParagraph() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph.removeAll() }
        }
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let active = fence {
                if trimmed.hasPrefix(active), trimmed.drop(while: { $0 == active.first }).trimmingCharacters(in: .whitespaces).isEmpty {
                    result.append(.code(language: language ?? "", text: code.joined(separator: "\n")))
                    code.removeAll(); language = nil; fence = nil
                } else { code.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~"), let marker = trimmed.first {
                let token = trimmed.prefix(while: { $0 == marker })
                let info = trimmed.dropFirst(token.count)
                if marker != "`" || !info.contains("`") {
                    flushParagraph()
                    fence = String(token)
                    language = info.trimmingCharacters(in: .whitespaces)
                    continue
                }
            }
            let parsed = MarkdownLine(line)
            if let level = parsed.underlineLevel, paragraph.count == 1 {
                result.append(.heading(level: level, text: paragraph.removeLast()))
                continue
            }
            let content = (line as NSString).substring(with: parsed.content)
            switch parsed.kind {
            case .blank: flushParagraph()
            case .paragraph: paragraph.append(line)
            case .heading(let level): flushParagraph(); result.append(.heading(level: level, text: content))
            case .quote: flushParagraph(); result.append(.quote(content))
            case .list(_, let checked): flushParagraph(); result.append(.listItem(text: content, checked: checked))
            case .divider: flushParagraph(); result.append(.divider)
            }
        }
        if fence != nil { result.append(.code(language: language ?? "", text: code.joined(separator: "\n"))) }
        flushParagraph()
        return result
    }
}
