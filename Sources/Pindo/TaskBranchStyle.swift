import AppKit

enum TaskBranchPalette {
    static let paper = adaptive(light: 0xFBFAF7, dark: 0x211F1D)
    static let toolbar = adaptive(light: 0xF3F0E9, dark: 0x292622)
    static let card = adaptive(light: 0xFFFDFA, dark: 0x292622)
    static let line = adaptive(light: 0xE4DDD2, dark: 0x453D35)
    static let accent = adaptive(light: 0x276450, dark: 0x9DDDC1)
    static let accentWash = adaptive(light: 0xE8F0E8, dark: 0x2D4036)
    static let inProgress = adaptive(light: 0x845413, dark: 0xF1BE76)
    static let cornerRadius: CGFloat = 4

    private static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
    }
}

struct TaskBranchRowStyle: Equatable {
    let isHeader: Bool
    let progress: String?
    let groupName: String?
    let notePreview: String?

    static var groupFont: NSFont { .systemFont(ofSize: 11) }
    static var progressFont: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .medium) }
    static let accessoryGap: CGFloat = 5

    var groupWidth: CGFloat {
        guard let groupName else { return 0 }
        return min(76, 18 + ceil((groupName as NSString).size(withAttributes: [.font: Self.groupFont]).width))
    }
    var progressWidth: CGFloat {
        guard let progress else { return 0 }
        return 12 + ceil((progress as NSString).size(withAttributes: [.font: Self.progressFont]).width)
    }
    static func preview(of note: String) -> String? {
        guard let firstLine = note.split(maxSplits: 1, whereSeparator: \.isNewline).first else { return nil }
        let excerpt = firstLine.prefix(160).trimmingCharacters(in: .whitespaces)
        return excerpt.isEmpty ? nil : excerpt
    }
}
