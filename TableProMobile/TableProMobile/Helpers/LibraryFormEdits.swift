import Foundation
import TableProModels

nonisolated struct GroupFormEdits: Equatable, Sendable {
    let name: String
    let color: ConnectionColor
    let parentId: UUID?

    init(name: String, color: ConnectionColor, parentId: UUID?) {
        self.name = name.trimmingCharacters(in: .whitespaces)
        self.color = color
        self.parentId = parentId
    }

    init(group: ConnectionGroup) {
        self.init(name: group.name, color: group.color, parentId: group.parentId)
    }

    func applied(to base: ConnectionGroup, changedSince opening: GroupFormEdits?) -> ConnectionGroup {
        func changed<Value: Equatable>(_ field: KeyPath<GroupFormEdits, Value>) -> Bool {
            guard let opening else { return true }
            return opening[keyPath: field] != self[keyPath: field]
        }

        var group = base
        if changed(\.name) { group.name = name }
        if changed(\.color) { group.color = color }
        if changed(\.parentId) { group.parentId = parentId }
        return group
    }
}

nonisolated struct TagFormEdits: Equatable, Sendable {
    let name: String
    let color: ConnectionColor

    init(name: String, color: ConnectionColor) {
        self.name = name
        self.color = color
    }

    init(tag: ConnectionTag) {
        self.init(name: tag.name, color: tag.color)
    }

    func applied(to base: ConnectionTag, changedSince opening: TagFormEdits?) -> ConnectionTag {
        func changed<Value: Equatable>(_ field: KeyPath<TagFormEdits, Value>) -> Bool {
            guard let opening else { return true }
            return opening[keyPath: field] != self[keyPath: field]
        }

        var tag = base
        if changed(\.name) { tag.name = name }
        if changed(\.color) { tag.color = color }
        return tag
    }
}

extension GroupFormEdits {
    @MainActor
    func save(editing existing: ConnectionGroup?, in appState: AppState) -> LibraryWriteOutcome {
        guard let existing else {
            return appState.addGroup(applied(to: ConnectionGroup(), changedSince: nil))
        }
        let opening = GroupFormEdits(group: existing)
        return appState.mutateGroup(existing.id) { $0 = applied(to: $0, changedSince: opening) }
    }
}

extension TagFormEdits {
    @MainActor
    func save(editing existing: ConnectionTag?, in appState: AppState) -> LibraryWriteOutcome {
        guard let existing else {
            return appState.addTag(applied(to: ConnectionTag(), changedSince: nil))
        }
        let opening = TagFormEdits(tag: existing)
        return appState.mutateTag(existing.id) { $0 = applied(to: $0, changedSince: opening) }
    }
}
