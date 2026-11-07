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
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let marker = trimmed.first!
                let length = trimmed.prefix(while: { $0 == marker }).count
                fence = String(repeating: String(marker), count: length)
                language = String(trimmed.dropFirst(length)).trimmingCharacters(in: .whitespaces); continue
            }
            if trimmed.isEmpty { flushParagraph(); continue }
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                flushParagraph(); result.append(.heading(level: hashes, text: String(trimmed.dropFirst(hashes + 1)))); continue
            }
            if ["---", "***", "___"].contains(trimmed) { flushParagraph(); result.append(.divider); continue }
            if trimmed.hasPrefix("> ") { flushParagraph(); result.append(.quote(String(trimmed.dropFirst(2)))); continue }
            var item: String?
            if ["- ", "* ", "+ "].contains(where: { trimmed.hasPrefix($0) }) { item = String(trimmed.dropFirst(2)) }
            else {
                let digits = trimmed.prefix(while: { $0.isNumber }).count
                if digits > 0, trimmed.dropFirst(digits).hasPrefix(". ") { item = String(trimmed.dropFirst(digits + 2)) }
            }
            if let item {
                flushParagraph()
                if item.hasPrefix("[ ] ") { result.append(.listItem(text: String(item.dropFirst(4)), checked: false)) }
                else if item.lowercased().hasPrefix("[x] ") { result.append(.listItem(text: String(item.dropFirst(4)), checked: true)) }
                else { result.append(.listItem(text: item, checked: nil)) }
            } else { paragraph.append(line) }
        }
        if fence != nil { result.append(.code(language: language ?? "", text: code.joined(separator: "\n"))) }
        flushParagraph()
        return result
    }
}
