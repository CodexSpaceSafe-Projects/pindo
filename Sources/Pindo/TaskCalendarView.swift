import SwiftUI
import PindoCore

struct TaskCalendarView: View {
    @ObservedObject var model: AppModel
    let dismiss: () -> Void
    @State private var month: DayKey

    init(model: AppModel, dismiss: @escaping () -> Void) {
        self.model = model; self.dismiss = dismiss
        _month = State(initialValue: model.selectedDay)
    }

    var body: some View {
        let counts = DayTaskCount.grouped(model.document.tasks.filter(model.matches))
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Text(month.date().formatted(.dateTime.year().month(.wide))).font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("今天") { model.selectedDay = model.today; dismiss() }.controlSize(.small)
                Button { month = CalendarMonth.shifting(month, months: -1) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 26) }.accessibilityLabel("上个月")
                Button { month = CalendarMonth.shifting(month, months: 1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 26) }.accessibilityLabel("下个月")
            }.buttonStyle(.borderless)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 5) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { Text($0).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).frame(height: 20) }
                ForEach(CalendarMonth.days(containing: month), id: \.self) { day in
                    dayCell(day, count: counts[day] ?? DayTaskCount())
                }
            }
            Divider()
            HStack(spacing: 16) {
                Label("未完成", systemImage: "circle.fill").foregroundStyle(.orange)
                Label("已完成", systemImage: "circle.fill").foregroundStyle(.green)
                Spacer()
                Text("按计划日期统计").foregroundStyle(.secondary)
            }.font(.system(size: 10))
        }.padding(18).frame(width: 354)
    }

    private func dayCell(_ day: DayKey, count: DayTaskCount) -> some View {
        let selected = day == model.selectedDay
        return Button { model.selectedDay = day; dismiss() } label: {
            VStack(spacing: 5) {
                Text("\(day.day)").font(.system(size: 13, weight: day == model.today || selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : day.month == month.month ? Color.primary : Color.secondary.opacity(0.5))
                HStack(spacing: 3) {
                    if count.unfinished > 0 { countBadge(count.unfinished, color: .orange, selected: selected) }
                    if count.completed > 0 { countBadge(count.completed, color: .green, selected: selected) }
                }.frame(height: 13)
            }.frame(maxWidth: .infinity).frame(height: 48)
                .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(day == model.today && !selected ? Color.accentColor.opacity(0.65) : .clear))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(day.description)，未完成 \(count.unfinished)，已完成 \(count.completed)")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func countBadge(_ count: Int, color: Color, selected: Bool) -> some View {
        Text(count > 99 ? "99+" : "\(count)").font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(selected ? color.opacity(0.95) : color)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(selected ? Color.white : color.opacity(0.12), in: Capsule())
    }
}
