import SwiftUI
import PindoCore

struct MarkdownPreview: View {
    let source: String
    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if source.isEmpty { Text("暂无备注").foregroundStyle(.secondary) }
                ForEach(Array(NoteMarkdown.blocks(source).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .heading(let level, let text): inline(text).font(.system(size: CGFloat(max(14, 24 - level * 2)), weight: .semibold))
                    case .paragraph(let text): inline(text)
                    case .quote(let text):
                        HStack { RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.3)).frame(width: 3); inline(text).foregroundStyle(.secondary) }
                    case .listItem(let text, let checked):
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let checked { Image(systemName: checked ? "checkmark.square" : "square") } else { Text("•") }
                            inline(text)
                        }
                    case .code(let language, let text):
                        VStack(alignment: .leading, spacing: 5) {
                            if !language.isEmpty { Text(language).font(.caption).foregroundStyle(.secondary) }
                            Text(text).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    case .divider: Divider()
                    }
                }
            }.font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }.environment(\.openURL, OpenURLAction { url in
            ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }
}
