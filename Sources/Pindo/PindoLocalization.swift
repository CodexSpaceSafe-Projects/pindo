import Foundation
import SwiftUI
import PindoCore

enum InterfaceLanguage: String, CaseIterable, Hashable {
    case automatic, english = "en", simplifiedChinese = "zh-Hans"

    static let defaultsKey = "interfaceLanguage"

    init(defaults: UserDefaults) {
        self = defaults.string(forKey: Self.defaultsKey).flatMap(Self.init(rawValue:)) ?? .automatic
    }

    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
        guard self == .automatic else { return self }
        let code = preferredLanguages.first.flatMap { Locale.Language(identifier: $0).languageCode?.identifier }
        return code == "zh" ? .simplifiedChinese : .english
    }
}

struct PindoLocalization {
    let language: InterfaceLanguage
    var locale: Locale { Locale(identifier: language.rawValue) }

    init(_ preference: InterfaceLanguage = .automatic, preferredLanguages: [String] = Locale.preferredLanguages) {
        language = preference.resolved(preferredLanguages: preferredLanguages)
    }

    private static let resources: Bundle = Bundle.main.bundleIdentifier == "com.pindo.Pindo" ? .main : .module
    private static let translations: [InterfaceLanguage: Bundle] = {
        Dictionary(uniqueKeysWithValues: [InterfaceLanguage.english, .simplifiedChinese].compactMap { language in
            guard let url = resources.url(forResource: language.rawValue, withExtension: "lproj"),
                  let bundle = Bundle(url: url) else { return nil }
            return (language, bundle)
        })
    }()

    func callAsFunction(_ key: String, _ arguments: CVarArg...) -> String { format(key, arguments) }

    func format(_ key: String, _ arguments: [CVarArg]) -> String {
        let value = Self.translations[language]?.localizedString(forKey: key, value: key, table: "Pindo") ?? key
        return arguments.isEmpty ? value : String(format: value, locale: locale, arguments: arguments)
    }

    func error(_ error: Error) -> String {
        if error is CloudSyncError || error is SyncTransportError { return self(error.localizedDescription) }
        if let failure = error as? HotkeyRegistrationError {
            switch failure {
            case .handlerUnavailable: return self("系统热键处理器未能启动。")
            case .unavailable(let binding): return self("快捷键 %@ 未能注册，可能已被占用；原快捷键保留。", binding)
            }
        }
        guard let error = error as? PindoError else { return error.localizedDescription }
        switch error {
        case .invalidData(let reason): return self("资料无效：%@。", self(reason))
        case .corruptFile(let file): return self("无法读取 %@，原文件已保留。", file)
        default: return self(error.localizedDescription)
        }
    }

    var initialDocument: PindoDocument {
        var document = PindoDocument()
        for index in document.groups.indices { document.groups[index].name = self(document.groups[index].name) }
        return document
    }

    func snapshotLabel(_ label: String) -> String {
        switch label {
        case "保留范围的起点", "自动快照", "恢复前的保护快照", "恢复后的快照", "导入前的保护快照", "导入后的快照":
            return self(label)
        default: return label
        }
    }
}

enum PindoNotice {
    case text(String)
    case failure(Error, context: String? = nil)

    func resolve(in strings: PindoLocalization) -> String {
        switch self {
        case .text(let key): return strings(key)
        case .failure(let error, let context):
            let detail = strings.error(error)
            return context.map { strings($0, detail) } ?? detail
        }
    }
}

private struct PindoLocalizationKey: EnvironmentKey {
    static let defaultValue = PindoLocalization()
}

extension EnvironmentValues {
    var pindoLocalization: PindoLocalization {
        get { self[PindoLocalizationKey.self] }
        set { self[PindoLocalizationKey.self] = newValue }
    }
}

struct LocalizedAppContent<Content: View>: View {
    @ObservedObject var model: AppModel
    let content: Content

    var body: some View {
        content.environment(\.pindoLocalization, model.localization)
            .environment(\.locale, model.localization.locale)
    }
}
