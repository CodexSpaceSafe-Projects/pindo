import SwiftUI
import PindoCore

struct QuickAddView: View {
    static let panelWidth: CGFloat = 470

    @Environment(\.pindoLocalization) private var l10n
    @ObservedObject var model: AppModel
    @State private var date = Date()
    @State private var groupID: UUID?
    @State private var showNote = false
    @State private var titleFocused = false
    private let finishEditing: () -> Void
    private let sizeChanged: (CGFloat) -> Void

    @MainActor init(model: AppModel, finishEditing: @escaping () -> Void = {}, sizeChanged: @escaping (CGFloat) -> Void = { _ in }) {
        self.model = model
        self.finishEditing = finishEditing
        self.sizeChanged = sizeChanged
        _groupID = State(initialValue: model.document.preferences.defaultGroupID)
    }

    private var canSave: Bool { !model.quickTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var accent: Color { Color(nsColor: TaskBranchPalette.accent) }
    private var paper: Color { Color(nsColor: TaskBranchPalette.paper) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                titleField
                options
                if showNote { noteEditor }
                ErrorBanner(model: model)
            }.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            footer
        }.frame(width: Self.panelWidth).fixedSize(horizontal: false, vertical: true)
            .background(paper)
            .background(GeometryReader { proxy in
                Color.clear.onAppear { sizeChanged(proxy.size.height) }
                    .onChange(of: proxy.size.height) { _, height in sizeChanged(height) }
            })
            .onAppear { showNote = !model.quickNote.isEmpty; titleFocused = true }
            .onChange(of: model.document.groups.map(\.id)) { _, ids in
                if let selected = groupID, !ids.contains(selected) { groupID = model.document.preferences.defaultGroupID }
            }
            .onExitCommand { model.hideQuickAdd() }
            .onDisappear { model.persistDrafts() }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(paper).frame(width: 24, height: 24)
                .background(accent, in: RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
            Text(l10n("添加事项")).font(.system(size: 16, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Spacer()
            Button { model.hideQuickAdd() } label: {
                Text(verbatim: "Esc").font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary).padding(.horizontal, 7).frame(height: 24)
                    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
            }.buttonStyle(.plain).accessibilityLabel(l10n("关闭快速记录"))
        }.padding(.horizontal, 16).frame(height: 44)
            .background(Color(nsColor: TaskBranchPalette.toolbar))
    }

    private var titleField: some View {
        TaskTitleEditor(text: $model.quickTitle, fontChoice: model.fontPreferences.task, defaultSize: 19, variant: .regular,
                        maximumLines: 1, placeholder: "有什么要做的？", allowsEmpty: true, isFocused: $titleFocused, onSubmit: save)
            .onChange(of: model.quickTitle) { _, _ in model.scheduleDraftSave() }
            .padding(.horizontal, 12).padding(.vertical, 9).frame(minHeight: 42)
            .background {
                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: TaskBranchPalette.card))
                    .onTapGesture { titleFocused = true }
            }
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(titleFocused ? accent.opacity(0.55) : Color(nsColor: TaskBranchPalette.line))
                .allowsHitTesting(false))
    }

    private var options: some View {
        HStack(spacing: 9) {
            DatePicker(l10n("计划日期"), selection: $date, displayedComponents: .date)
                .labelsHidden().fixedSize().controlSize(.small)
            GroupSelectionMenu(groups: model.document.groups, selection: $groupID)
            Spacer(minLength: 0)
            Button { showNote.toggle() } label: {
                Label(l10n(showNote ? "收起备注" : "添加备注"), systemImage: showNote ? "chevron.up" : "note.text")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(showNote ? accent : Color.secondary)
                    .padding(.horizontal, 9).frame(height: 30)
                    .background(Color(nsColor: showNote ? TaskBranchPalette.accentWash : TaskBranchPalette.toolbar),
                                in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain)
        }
    }

    private var noteEditor: some View {
        NoteEditor(text: $model.quickNote, fontChoice: model.fontPreferences.note, accessibilityName: l10n("快速记录备注"))
            .frame(height: 106)
            .background(Color(nsColor: TaskBranchPalette.card), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: TaskBranchPalette.line)).allowsHitTesting(false))
            .onChange(of: model.quickNote) { _, _ in model.scheduleDraftSave() }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(l10n(showNote ? "备注中 ⌘↵ 添加 · Esc 保留草稿" : "Return 添加 · Esc 保留草稿"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button(action: save) {
                Label(l10n("添加待办"), systemImage: "return")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(canSave ? paper : Color.secondary)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(canSave ? accent : Color(nsColor: TaskBranchPalette.accentWash), in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command).disabled(!canSave)
        }.padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color(nsColor: TaskBranchPalette.toolbar))
    }

    private func save() {
        guard canSave else { return }
        finishEditing()
        guard model.addTask(title: model.quickTitle, note: model.quickNote, day: DayKey(date), groupID: groupID) else { return }
        model.hideQuickAdd()
        model.quickTitle = ""; model.quickNote = ""
        model.persistDrafts()
    }
}
