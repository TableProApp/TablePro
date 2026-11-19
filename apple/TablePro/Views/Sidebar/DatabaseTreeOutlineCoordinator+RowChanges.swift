//
//  DatabaseTreeOutlineCoordinator+RowChanges.swift
//  TablePro
//

import AppKit

// What one parent's children did between two rebuilds. Rows are the same row when they are the same object.
enum DatabaseTreeRowChange: Equatable {
    case none
    case rows(removed: IndexSet, inserted: IndexSet)
    // The kept rows moved or repeat, or so many rows changed that one reload of the parent costs less.
    case reload

    private static let rowOperationFloor = 256

    // Rows that stayed put at either end are skipped by pointer: a load usually changes a few rows of thousands.
    static func between(_ old: [DatabaseTreeNode], _ new: [DatabaseTreeNode]) -> DatabaseTreeRowChange {
        var head = 0
        while head < old.count, head < new.count, old[head] === new[head] { head += 1 }
        if head == old.count, head == new.count { return .none }
        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > head, newEnd > head, old[oldEnd - 1] === new[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }

        let oldRows = Set(old[head..<oldEnd].map { ObjectIdentifier($0) })
        let newRows = Set(new[head..<newEnd].map { ObjectIdentifier($0) })
        guard oldRows.count == oldEnd - head, newRows.count == newEnd - head else { return .reload }

        let removed = (head..<oldEnd).filter { !newRows.contains(ObjectIdentifier(old[$0])) }
        let inserted = (head..<newEnd).filter { !oldRows.contains(ObjectIdentifier(new[$0])) }
        guard removed.count + inserted.count <= max(rowOperationFloor, old.count) else { return .reload }

        let keptOld = (head..<oldEnd).lazy.filter { newRows.contains(ObjectIdentifier(old[$0])) }.map { old[$0] }
        let keptNew = (head..<newEnd).lazy.filter { oldRows.contains(ObjectIdentifier(new[$0])) }.map { new[$0] }
        guard keptOld.elementsEqual(keptNew, by: { $0 === $1 }) else { return .reload }
        return .rows(removed: IndexSet(removed), inserted: IndexSet(inserted))
    }
}

extension DatabaseTreeOutlineCoordinator {
    // False with nothing applied when only a whole reload can say what changed. AppKit asks a closed row for its
    // children each time it opens, so only the open rows are walked.
    internal func applyRowChanges(
        from drawnChildren: [String: [DatabaseTreeNode]],
        in outlineView: NSOutlineView
    ) -> Bool {
        var changes: [(parent: DatabaseTreeNode?, change: DatabaseTreeRowChange)] = []
        var pending: [DatabaseTreeNode?] = [nil]
        while let parent = pending.popLast() {
            guard let drawn = drawnChildren[parent?.id ?? ""] else { return false }
            let children = resolvedChildren(of: parent)
            let change = DatabaseTreeRowChange.between(drawn, children)
            guard canApply(change, children: children, under: parent, in: outlineView) else { return false }
            if change != .none { changes.append((parent, change)) }
            // A reloaded parent takes the rows under it along.
            if change != .reload {
                pending += children.filter { $0.isExpandable && outlineView.isItemExpanded($0) }
            }
        }
        for (parent, change) in changes {
            apply(change, under: parent, in: outlineView)
        }
        return true
    }

    // A row still on screen under another parent moved there, which row operations on one parent cannot express.
    private func canApply(
        _ change: DatabaseTreeRowChange,
        children: [DatabaseTreeNode],
        under parent: DatabaseTreeNode?,
        in outlineView: NSOutlineView
    ) -> Bool {
        switch change {
        case .none:
            return true
        case .rows(_, let inserted):
            return inserted.allSatisfy { outlineView.row(forItem: children[$0]) < 0 }
        case .reload:
            return children.allSatisfy { child in
                outlineView.row(forItem: child) < 0 || outlineView.parent(forItem: child) as? DatabaseTreeNode === parent
            }
        }
    }

    private func apply(_ change: DatabaseTreeRowChange, under parent: DatabaseTreeNode?, in outlineView: NSOutlineView) {
        switch change {
        case .none:
            break
        case .rows(let removed, let inserted):
            if !removed.isEmpty { outlineView.removeItems(at: removed, inParent: parent, withAnimation: []) }
            if !inserted.isEmpty { outlineView.insertItems(at: inserted, inParent: parent, withAnimation: []) }
        case .reload:
            outlineView.reloadItem(parent, reloadChildren: true)
        }
    }
}
