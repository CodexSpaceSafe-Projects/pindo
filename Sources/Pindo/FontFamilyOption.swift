import Combine
import CoreText
import Foundation

struct FontFamilyOption: Identifiable, Equatable, Sendable {
    let id: String
    let title: String

    init(_ family: String) {
        id = family
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        if CTFontCopyFamilyName(font) as String == family,
           let chinese = Self.chineseName(for: font), chinese != family {
            title = "\(chinese) · \(family)"
        } else {
            title = family
        }
    }

    private static func chineseName(for font: CTFont) -> String? {
        var language: Unmanaged<CFString>?
        let name = CTFontCopyLocalizedName(font, kCTFontFamilyNameKey, &language) as String?
        let languageCode = language?.takeRetainedValue() as String?
        if let name, languageCode?.lowercased().hasPrefix("zh") == true,
           containsIdeographs(name) { return name }

        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableName), []) as Data? else { return nil }
        return chineseName(in: table)
    }

    // 系统语言不优先选择中文时，读取字体自己的中文家族名。菜单仍用原家族名存储选择。
    static func chineseName(in table: Data) -> String? {
        let bytes = Array(table)
        guard bytes.count >= 6 else { return nil }
        func word(_ offset: Int) -> Int { Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) }
        let count = word(2), storage = word(4), recordsEnd = 6 + count * 12
        guard recordsEnd <= storage, storage <= bytes.count else { return nil }

        func string(length: Int, offset: Int, encoding: String.Encoding) -> String? {
            let start = storage + offset, end = start + length
            guard length > 0, end <= bytes.count else { return nil }
            return String(bytes: bytes[start..<end], encoding: encoding)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func languageTag(_ id: Int) -> String? {
            guard word(0) == 1, id >= 0x8000, recordsEnd + 2 <= storage, id - 0x8000 < word(recordsEnd) else { return nil }
            let record = recordsEnd + 2 + (id - 0x8000) * 4
            guard record + 4 <= storage else { return nil }
            return string(length: word(record), offset: word(record + 2), encoding: .utf16BigEndian)?.lowercased()
        }

        var best: (rank: Int, name: String)?
        for index in 0..<count {
            let record = 6 + index * 12
            let platform = word(record), encodingID = word(record + 2), language = word(record + 4), nameID = word(record + 6)
            guard nameID == 1 || nameID == 16 else { continue }
            let encoding: String.Encoding
            let simplified: Bool
            if platform == 1, language == 19 || language == 33 {
                let macEncoding: CFStringEncodings = language == 33 ? .macChineseSimp : .macChineseTrad
                encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(macEncoding.rawValue)))
                simplified = language == 33
            } else if platform == 0 || (platform == 3 && [1, 10].contains(encodingID)) {
                encoding = .utf16BigEndian
                if let tag = languageTag(language), tag == "zh" || tag.hasPrefix("zh-") {
                    simplified = tag.contains("hans") || tag == "zh-cn" || tag == "zh-sg"
                } else if platform == 3, language & 0x03FF == 4 {
                    simplified = language == 0x0804 || language == 0x1004
                } else { continue }
            } else { continue }
            let rank = (simplified ? 4 : 0) + (nameID == 16 ? 2 : 0) + (platform == 1 ? 0 : 1)
            guard rank > (best?.rank ?? -1),
                  let name = string(length: word(record + 8), offset: word(record + 10), encoding: encoding),
                  containsIdeographs(name) else { continue }
            best = (rank, name)
        }
        return best?.name
    }

    private static func containsIdeographs(_ name: String) -> Bool {
        name.unicodeScalars.contains { $0.properties.isIdeographic }
    }
}

@MainActor final class FontFamilyCatalog: ObservableObject {
    static let shared = FontFamilyCatalog()
    @Published private(set) var options: [FontFamilyOption]?
    private var loading = false

    func prepare() {
        guard !loading else { return }
        loading = true
        let previous = options
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                guard let families = CTFontManagerCopyAvailableFontFamilyNames() as? [String] else {
                    return previous ?? []
                }
                let names = Set(families)
                if let previous, names == Set(previous.map(\.id)) { return previous }
                return names.map { FontFamilyOption($0) }
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            }.value
            if options != loaded { options = loaded }
            loading = false
        }
    }
}
