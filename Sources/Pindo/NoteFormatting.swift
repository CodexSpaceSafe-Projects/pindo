import AppKit
import MarkdownEngine

enum NoteFormat: Int, CaseIterable {
    case bold, italic, strike, inlineCode, link
    case heading, quote, bullet, ordered, task, codeBlock

    var title: String {
        switch self {
        case .bold: "加粗"
        case .italic: "斜体"
        case .strike: "删除线"
        case .inlineCode: "行内代码"
        case .link: "插入链接"
        case .heading: "二级标题"
        case .quote: "引用"
        case .bullet: "项目列表"
        case .ordered: "编号列表"
        case .task: "任务列表"
        case .codeBlock: "代码块"
        }
    }

}

@MainActor extension NoteEditor.Coordinator {
    private func request(_ format: NoteFormat) -> Notification.Name {
        Notification.Name("Pindo.NoteEditor.\(documentID).\(format.rawValue)")
    }

    var formatBus: MarkdownEditorBus {
        MarkdownEditorBus(applyBoldRequest: request(.bold), applyItalicRequest: request(.italic),
            applyHeadingRequest: request(.heading), applyStrikethroughRequest: request(.strike),
            applyInlineCodeRequest: request(.inlineCode), applyBlockquoteRequest: request(.quote),
            applyUnorderedListRequest: request(.bullet), applyOrderedListRequest: request(.ordered),
            applyLinkRequest: request(.link), applyCodeBlockRequest: request(.codeBlock))
    }

    func applyFormat(_ format: NoteFormat) {
        guard let view = textView, view.isEditable, !view.hasMarkedText() else { return }
        if format == .task {
            let source = view.string as NSString
            let selection = source.lineRange(for: view.selectedRange())
            var starts: [Int] = [], offset = selection.location
            repeat {
                starts.append(offset)
                offset = NSMaxRange(source.lineRange(for: NSRange(location: offset, length: 0)))
            } while offset > starts.last! && offset < NSMaxRange(selection)
            view.breakUndoCoalescing()
            view.undoManager?.beginUndoGrouping()
            for start in starts.reversed() {
                view.insertText("- [ ] ", replacementRange: NSRange(location: start, length: 0))
            }
            view.undoManager?.endUndoGrouping()
            view.breakUndoCoalescing()
        } else {
            let info: [String: Any]? = format == .heading ? ["level": 2] : format == .link ? ["url": "https://"] : nil
            NotificationCenter.default.post(name: request(format), object: nil, userInfo: info)
        }
        commit()
    }

    func formatMenu(_ menu: NSMenu) -> NSMenu {
        guard let view = textView, view.isEditable, !view.hasMarkedText() else { return menu }
        let label = parent.localization("Markdown 格式")
        let formats = NSMenu(title: label)
        formats.autoenablesItems = false
        for format in NoteFormat.allCases {
            if format == .heading { formats.addItem(.separator()) }
            let item = NSMenuItem(title: parent.localization(format.title), action: #selector(performFormat(_:)), keyEquivalent: "")
            item.target = self; item.tag = format.rawValue
            formats.addItem(item)
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        item.submenu = formats; menu.addItem(item)
        return menu
    }

    @objc func performFormat(_ item: NSMenuItem) {
        if let format = NoteFormat(rawValue: item.tag) { applyFormat(format) }
    }
}
