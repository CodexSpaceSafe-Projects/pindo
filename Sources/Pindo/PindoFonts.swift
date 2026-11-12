import AppKit
import CoreText
import SwiftUI

struct PindoFontPreferences: Codable, Equatable {
    static let defaultsKey = "fontPreferences"
    static let taskDefaultSize = 16
    static let noteDefaultSize = 14

    var task = PindoFontChoice()
    var note = PindoFontChoice()
}

struct PindoFontChoice: Codable, Equatable {
    enum Variant: Hashable { case regular, semibold, monospaced }
    static let pointSizes = 10...36

    var primaryFamily: String?
    var fallbackFamily: String?
    var pointSize: Int?

    func effectiveSize(defaultSize: Int) -> Int {
        guard let pointSize else { return defaultSize }
        return min(max(pointSize, Self.pointSizes.lowerBound), Self.pointSizes.upperBound)
    }

    @MainActor func swiftUIFont(defaultSize: Int, variant: Variant = .regular) -> Font {
        if primaryFamily == nil, fallbackFamily == nil {
            return .system(size: CGFloat(effectiveSize(defaultSize: defaultSize)), weight: variant == .semibold ? .semibold : .regular,
                           design: variant == .monospaced ? .monospaced : .default)
        }
        return Font(font(defaultSize: defaultSize, variant: variant))
    }

    @MainActor func font(defaultSize: Int, offset: Int = 0, variant: Variant = .regular) -> NSFont {
        let size = CGFloat(effectiveSize(defaultSize: defaultSize) + offset)
        let request = FontRequest(family: primaryFamily, fallback: fallbackFamily, size: size, variant: variant)
        if let font = Self.cache[request] { return font }

        let weight = variant == .semibold ? 8 : 5
        let primary = primaryFamily.flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: weight, size: size) }
        let base: NSFont
        switch variant {
        case .regular: base = primary ?? .systemFont(ofSize: size)
        case .semibold: base = primary ?? .systemFont(ofSize: size, weight: .semibold)
        case .monospaced:
            if let primary, primary.isFixedPitch { base = primary }
            else { base = .monospacedSystemFont(ofSize: size, weight: .regular) }
        }

        let font = addingFallback(to: base)
        if Self.cache.count >= 96 { Self.cache.removeAll(keepingCapacity: true) }
        Self.cache[request] = font
        return font
    }

    @MainActor func applying(_ trait: NSFontTraitMask, to font: NSFont) -> NSFont {
        addingFallback(to: NSFontManager.shared.convert(font, toHaveTrait: trait))
    }

    @MainActor private func addingFallback(to font: NSFont) -> NSFont {
        guard let fallbackFamily, fallbackFamily != font.familyName else { return font }
        let manager = NSFontManager.shared
        let traits = manager.traits(of: font).intersection([.boldFontMask, .italicFontMask])
        let fallback = manager.font(withFamily: fallbackFamily, traits: traits, weight: manager.weight(of: font), size: font.pointSize)
            ?? manager.font(withFamily: fallbackFamily, traits: [], weight: 5, size: font.pointSize)
        guard let fallback else { return font }

        // 把备用字体排在系统补字列表前，让两种字体都缺少的字符仍可正常显示。
        let systemCascade = CTFontCopyDefaultCascadeListForLanguages(font as CTFont, Locale.preferredLanguages as CFArray)
            as? [NSFontDescriptor] ?? []
        let descriptor = font.fontDescriptor.addingAttributes([.cascadeList: [fallback.fontDescriptor] + systemCascade])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    private struct FontRequest: Hashable {
        let family: String?
        let fallback: String?
        let size: CGFloat
        let variant: Variant
    }

    @MainActor private static var cache: [FontRequest: NSFont] = [:]
}
