import Foundation

/// Stable identities and child order, without row content or AppKit objects. A live
/// drag normally changes exactly one subtree's position; recognize that operation
/// so the native outline can animate it without replacing unrelated rows.
public struct TaskOutlineStructure: Equatable, Sendable {
    public static let root = "$root"
    public let children: [String: [String]]

    public init(children: [String: [String]]) { self.children = children }

    public func singleMove(to next: Self, preferredID: String?) -> TaskOutlineMove? {
        guard children != next.children, Set(children.keys) == Set(next.children.keys) else { return nil }
        struct Location: Equatable { let parent: String; let index: Int }
        func locations(_ structure: Self) -> [String: Location] {
            var result: [String: Location] = [:]
            for (parent, ids) in structure.children {
                for (index, id) in ids.enumerated() { result[id] = Location(parent: parent, index: index) }
            }
            return result
        }
        let old = locations(self), new = locations(next)
        guard Set(old.keys) == Set(new.keys) else { return nil }
        let reparented = old.keys.filter { old[$0]?.parent != new[$0]?.parent }
        var candidates = preferredID.map { [$0] } ?? []
        if reparented.count == 1 { candidates.append(reparented[0]) }
        else if reparented.isEmpty {
            // The dragged identity disambiguates adjacent swaps. A minimal diff is
            // also useful when applying a saved reorder after the session ends.
            for (parent, ids) in children where ids != next.children[parent] {
                let diff = (next.children[parent] ?? []).difference(from: ids).inferringMoves()
                if diff.removals.count == 1, case let .remove(_, id, _) = diff.removals[0] { candidates.append(id) }
            }
        } else { return nil }
        for id in candidates {
            guard let from = old[id], let to = new[id], from != to else { continue }
            var projected = children
            projected[from.parent]?.remove(at: from.index)
            guard to.index <= (projected[to.parent]?.count ?? -1) else { continue }
            projected[to.parent]?.insert(id, at: to.index)
            if projected == next.children {
                return TaskOutlineMove(id: id, oldParent: from.parent, oldIndex: from.index, newParent: to.parent, newIndex: to.index)
            }
        }
        return nil
    }
}

public struct TaskOutlineMove: Equatable, Sendable {
    public let id: String
    public let oldParent: String
    public let oldIndex: Int
    public let newParent: String
    public let newIndex: Int
}
