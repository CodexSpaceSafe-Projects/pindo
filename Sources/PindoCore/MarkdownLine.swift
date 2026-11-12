import Foundation

package struct MarkdownLine {
    package enum Kind: Equatable {
        case blank, paragraph, divider
        case heading(Int)
        case quote(Int)
        case list(ordered: Bool, checked: Bool?)
    }

    package let kind: Kind
    // 相对于原始行的 UTF-16 范围。标记保留在正文中，渲染器可以单独显示或隐藏。
    package let content: NSRange
    package let markerStart: Int
    package let underlineLevel: Int?

    private static let heading = try! NSRegularExpression(pattern: #"^ {0,3}(#{1,6})(?:[ \t]+|$)"#)
    private static let headingEnd = try! NSRegularExpression(pattern: #"[ \t]+#+[ \t]*$"#)
    private static let quote = try! NSRegularExpression(pattern: #"^ {0,3}(?:>[ \t]?)+"#)
    private static let list = try! NSRegularExpression(pattern: #"^[ \t]*([-+*]|[0-9]{1,9}[.)])[ \t]+(?:\[([ xX])\](?:[ \t]+|$))?"#)
    private static let divider = try! NSRegularExpression(pattern: #"^ {0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$"#)
    private static let underline = try! NSRegularExpression(pattern: #"^ {0,3}(=+|-+)[ \t]*$"#)

    package init(_ line: String) {
        let source = line as NSString
        let whole = NSRange(location: 0, length: source.length)
        let first = line.drop(while: { $0 == " " || $0 == "\t" }).first
        if first == "=" || first == "-", let underline = Self.underline.firstMatch(in: line, range: whole) {
            underlineLevel = source.character(at: underline.range(at: 1).location) == 61 ? 1 : 2
        } else {
            underlineLevel = nil
        }

        var listMarkerStart = 0
        if first == nil || (first?.isWhitespace == true && line.allSatisfy(\.isWhitespace)) {
            kind = .blank
            content = whole
        } else if first == "#", let match = Self.heading.firstMatch(in: line, range: whole) {
            kind = .heading(match.range(at: 1).length)
            let start = NSMaxRange(match.range)
            let rest = NSRange(location: start, length: source.length - start)
            let end = Self.headingEnd.firstMatch(in: line, range: rest)?.range.location ?? source.length
            content = NSRange(location: start, length: end - start)
        } else if (first == "-" || first == "*" || first == "_"), Self.divider.firstMatch(in: line, range: whole) != nil {
            kind = .divider
            content = NSRange(location: 0, length: 0)
        } else if first == ">", let match = Self.quote.firstMatch(in: line, range: whole) {
            let depth = source.substring(with: match.range).filter { $0 == ">" }.count
            kind = .quote(depth)
            content = NSRange(location: NSMaxRange(match.range), length: source.length - NSMaxRange(match.range))
        } else if (first == "-" || first == "*" || first == "+" || first?.isNumber == true),
                  let match = Self.list.firstMatch(in: line, range: whole) {
            let marker = match.range(at: 1)
            listMarkerStart = marker.location
            let checkbox = match.range(at: 2)
            let checked = checkbox.location == NSNotFound ? nil : source.substring(with: checkbox) != " "
            kind = .list(ordered: marker.length > 1, checked: checked)
            content = NSRange(location: NSMaxRange(match.range), length: source.length - NSMaxRange(match.range))
        } else {
            kind = .paragraph
            content = whole
        }
        markerStart = listMarkerStart
    }
}
