import Foundation

/// UTF-16 ranges of graphemes that need extra advance before the next visible
/// grapheme. The source, including existing whitespace, is never rewritten.
public enum MixedScriptSpacing {
    public static let em = 0.125

    public static func kerningRanges(in text: String, hidden: [NSRange] = [], verbatim: [NSRange] = []) -> [NSRange] {
        let hidden = hidden.sorted { $0.location < $1.location }
        let verbatim = verbatim.sorted { $0.location < $1.location }
        var hiddenIndex = 0, verbatimIndex = 0, offset = 0
        var previous: (kind: Script, range: NSRange, verbatim: Bool)?
        var result: [NSRange] = []
        for character in text {
            let value = String(character)
            let range = NSRange(location: offset, length: value.utf16.count)
            offset += range.length
            while hiddenIndex < hidden.count, NSMaxRange(hidden[hiddenIndex]) <= range.location { hiddenIndex += 1 }
            if hiddenIndex < hidden.count, NSIntersectionRange(hidden[hiddenIndex], range).length > 0 { continue }
            while verbatimIndex < verbatim.count, NSMaxRange(verbatim[verbatimIndex]) <= range.location { verbatimIndex += 1 }
            let isVerbatim = verbatimIndex < verbatim.count && NSIntersectionRange(verbatim[verbatimIndex], range).length > 0
            let kind = script(of: value)
            if let previous, !(previous.verbatim && isVerbatim),
               (previous.kind == .han && kind == .western) || (previous.kind == .western && kind == .han) {
                result.append(previous.range)
            }
            previous = (kind, range, isVerbatim)
        }
        return result
    }

    private enum Script { case han, western, other }
    private static let han = try! NSRegularExpression(pattern: #"^\p{Han}"#)
    private static let western = try! NSRegularExpression(pattern: #"^[\p{Latin}\p{Nd}]"#)

    private static func script(of character: String) -> Script {
        let range = NSRange(location: 0, length: character.utf16.count)
        if han.firstMatch(in: character, range: range) != nil { return .han }
        // A keycap emoji is a pictograph, rather than a western digit.
        if !character.unicodeScalars.contains(where: { $0.value == 0x20E3 }), western.firstMatch(in: character, range: range) != nil {
            return .western
        }
        return .other
    }
}
