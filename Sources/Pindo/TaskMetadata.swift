import Foundation
import SwiftUI
import PindoCore

extension TaskPhase {
    var titleKey: String {
        switch self {
        case .pending: return "未完成"
        case .inProgress: return "进行中"
        case .completed: return "已完成"
        }
    }
}

struct TaskMetadata {
    let item: TodoItem
    let groupName: String?
    let parentTitle: String?

    // 旧版本的未完成事项可能仍有上一轮的开始时间。
    var startedAt: Date? { item.phase == .pending ? nil : item.startedAt }
    var completedAt: Date? { item.phase == .completed ? item.completedAt : nil }

    func json() throws -> String {
        let time = ISO8601DateFormatter()
        time.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        time.timeZone = TimeZone(secondsFromGMT: 0)
        func field(_ text: String?) -> JSONValue { text.map(JSONValue.string) ?? .null }
        let fields: [String: JSONValue] = [
            "source": .string("Pindo"),
            "id": .string(item.id.uuidString),
            "title": .string(item.title),
            "phase": .string(item.phase.rawValue),
            "plannedDay": .string(item.plannedDay.description),
            "createdAt": .string(time.string(from: item.createdAt)),
            "startedAt": field(startedAt.map(time.string(from:))),
            "completedAt": field(completedAt.map(time.string(from:))),
            "groupID": field(item.groupID?.uuidString),
            "groupName": field(groupName),
            "parentID": field(item.parentID?.uuidString),
            "parentTitle": field(parentTitle)
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(fields), as: UTF8.self)
    }
}

struct TaskMetadataView: View {
    @Environment(\.pindoLocalization) private var l10n
    @State private var copyResult: Bool?
    let metadata: TaskMetadata
    let copy: () -> Bool

    var body: some View {
        DisclosureGroup(l10n("事项元数据")) {
            VStack(alignment: .leading, spacing: 7) {
                LabeledContent(l10n("事项 ID")) {
                    Text(metadata.item.id.uuidString).font(.system(size: 10, design: .monospaced))
                }
                LabeledContent(l10n("状态"), value: l10n(metadata.item.phase.titleKey))
                LabeledContent(l10n("添加时间"), value: formatted(metadata.item.createdAt))
                LabeledContent(l10n("开始执行时间"), value: formatted(metadata.startedAt))
                LabeledContent(l10n("完成时间"), value: formatted(metadata.completedAt))
                LabeledContent(l10n("分组"), value: metadata.groupName ?? l10n("未分组"))
                LabeledContent(l10n("父项"), value: metadata.parentTitle ?? "—")
            }.font(.system(size: 11)).textSelection(.enabled).padding(.vertical, 8)
            Button(l10n("复制事项元数据")) { copyResult = copy() }
            if let copyResult {
                Text(l10n(copyResult ? "已复制事项元数据" : "未能复制事项元数据。"))
                    .font(.system(size: 11)).foregroundStyle(copyResult ? Color.secondary : Color.red)
            }
        }
    }

    private func formatted(_ time: Date?) -> String {
        time?.formatted(.dateTime.year().month().day().hour().minute().second().locale(l10n.locale)) ?? "—"
    }
}
