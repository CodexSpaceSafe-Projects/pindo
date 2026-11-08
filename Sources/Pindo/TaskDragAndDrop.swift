import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PindoCore

private let taskDragType = UTType(exportedAs: "com.pindo.task-id")

struct TaskDragAndDrop: ViewModifier {
    @ObservedObject var model: AppModel
    let task: TodoItem
    @State private var height: CGFloat = 36
    @State private var position: TaskDropPosition?

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { proxy in
                Color.clear.onAppear { height = proxy.size.height }.onChange(of: proxy.size.height) { _, value in height = value }
            })
            .overlay {
                if let position {
                    if position == .inside {
                        RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor, lineWidth: 1.5).allowsHitTesting(false)
                    } else {
                        VStack(spacing: 0) {
                            if position == .after { Spacer(minLength: 0) }
                            Color.accentColor.frame(height: 2)
                            if position == .before { Spacer(minLength: 0) }
                        }.allowsHitTesting(false)
                    }
                }
            }
            .onDrag {
                model.draggedTaskID = task.id
                let provider = NSItemProvider()
                let data = Data(task.id.uuidString.utf8)
                provider.registerDataRepresentation(forTypeIdentifier: taskDragType.identifier, visibility: .ownProcess) { completion in
                    completion(data, nil); return nil
                }
                return provider
            }
            .onDrop(of: [taskDragType.identifier], delegate: TaskRowDropDelegate(model: model, target: task.id, height: height, position: $position))
    }
}

@MainActor private struct TaskRowDropDelegate: DropDelegate {
    let model: AppModel
    let target: UUID
    let height: CGFloat
    @Binding var position: TaskDropPosition?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [taskDragType.identifier]) && model.draggedTaskID != nil && model.draggedTaskID != target
    }
    func dropEntered(info: DropInfo) { _ = dropUpdated(info: info) }
    func dropExited(info: DropInfo) { position = nil }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let proposed = placement(info.location.y)
        guard let source = model.draggedTaskID, model.canDropTask(source, onto: target, position: proposed) else {
            position = nil; return DropProposal(operation: .cancel)
        }
        position = proposed
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        let proposed = placement(info.location.y)
        position = nil
        guard let source = model.draggedTaskID, model.canDropTask(source, onto: target, position: proposed),
              let provider = info.itemProviders(for: [taskDragType.identifier]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: taskDragType.identifier) { data, _ in
            Task { @MainActor in
                defer { model.draggedTaskID = nil }
                guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text), id == source else { return }
                _ = model.dropTask(id, onto: target, position: proposed)
            }
        }
        return true
    }
    private func placement(_ y: CGFloat) -> TaskDropPosition {
        if y < height * 0.25 { return .before }
        if y > height * 0.75 { return .after }
        return .inside
    }
}
