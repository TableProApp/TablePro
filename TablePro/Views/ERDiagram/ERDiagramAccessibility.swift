//
//  ERDiagramAccessibility.swift
//  TablePro
//
//  The diagram is drawn, so there is no view per table to carry a name. These publish one
//  accessibility element per table, and one per column under it, so VoiceOver reads the schema
//  instead of announcing a single image.
//
//  Nothing here is `@MainActor`. `accessibilityFrame()` and `accessibilityChildren()` override
//  members AppKit declares without isolation, so the overrides are nonisolated whatever the class
//  says, and an isolated member called from one of them will not compile. Every call still arrives
//  on the main thread, which is what the unchecked conformances rest on; the file touches only its
//  own stored values, nonisolated `setAccessibility*` setters and
//  `NSAccessibility.screenRect(fromView:rect:)`.
//

import AppKit

/// A table in the diagram.
///
/// The frame is computed on demand rather than stored. Measured on macOS 27:
/// `accessibilityFrameInParentSpace` honours neither the view's flip nor the scroll view's
/// magnification, so an element written that way is announced over a different table at any zoom
/// but 100%, and a *stored* `accessibilityFrame` goes stale on every zoom, scroll, window move and
/// layout pass. Computing it from the owning view answers correctly at every magnification and
/// scroll offset with nothing to invalidate.
final class ERDiagramNodeElement: NSAccessibilityElement, @unchecked Sendable {
    fileprivate weak var owner: NSView?
    fileprivate private(set) var rect: CGRect = .zero
    private var columns: [ERColumnDisplay] = []
    private var columnIdentities: [String] = []
    private var builtColumns: [ERDiagramColumnElement]?

    func configure(owner: NSView, node: ERTableNode, rect: CGRect, relationships: String?) {
        self.owner = owner
        self.rect = rect

        setAccessibilityRole(.layoutItem)
        setAccessibilityRoleDescription(String(localized: "table"))
        setAccessibilityLabel(node.tableName)
        setAccessibilityValue(String(format: String(localized: "%d columns"), node.displayColumns.count))
        setAccessibilityHelp(relationships)
        setAccessibilityParent(owner)

        // A drag rewrites the rect on every pointer event, and the column elements read their row
        // from this one, so they only have to be rebuilt when the columns themselves change.
        let identities = node.displayColumns.map(\.id)
        guard identities != columnIdentities else { return }
        columnIdentities = identities
        columns = node.displayColumns
        builtColumns = nil
    }

    fileprivate func rowRect(at index: Int) -> CGRect {
        CGRect(
            x: rect.minX,
            y: rect.minY + ERDiagramLayout.headerHeight + CGFloat(index) * ERDiagramLayout.columnRowHeight,
            width: rect.width,
            height: ERDiagramLayout.columnRowHeight
        )
    }

    override func accessibilityFrame() -> NSRect {
        guard let owner else { return .zero }
        return NSAccessibility.screenRect(fromView: owner, rect: rect)
    }

    /// Built on the first question rather than with the table, so a schema of five hundred tables
    /// does not pay for every column of every one of them before anything asks.
    override func accessibilityChildren() -> [Any]? {
        if let builtColumns { return builtColumns }
        let built = columns.enumerated().map { index, column -> ERDiagramColumnElement in
            let element = ERDiagramColumnElement()
            element.configure(node: self, column: column, index: index)
            return element
        }
        builtColumns = built
        return built
    }
}

/// One column row inside a table. Its rectangle follows the table's, so dragging a table carries
/// its columns along and nothing has to be rebuilt.
final class ERDiagramColumnElement: NSAccessibilityElement, @unchecked Sendable {
    private weak var node: ERDiagramNodeElement?
    private var index = 0

    func configure(node: ERDiagramNodeElement, column: ERColumnDisplay, index: Int) {
        self.node = node
        self.index = index

        var traits: [String] = [column.dataType]
        if column.isPrimaryKey { traits.append(String(localized: "primary key")) }
        if column.isForeignKey { traits.append(String(localized: "foreign key")) }
        traits.append(column.isNullable ? String(localized: "optional") : String(localized: "required"))

        setAccessibilityRole(.staticText)
        setAccessibilityLabel(column.name)
        setAccessibilityValue(traits.joined(separator: ", "))
        setAccessibilityParent(node)
    }

    override func accessibilityFrame() -> NSRect {
        guard let node, let owner = node.owner else { return .zero }
        return NSAccessibility.screenRect(fromView: owner, rect: node.rowRect(at: index))
    }
}

/// The element tree the scene view publishes, rebuilt only when something asks for it.
///
/// A node drag rewrites the scene on every pointer event. Building the tree there would rebuild
/// every element hundreds of times a second whether or not anything was listening, and would hand
/// a client a new object for the table it is reading.
final class ERDiagramAccessibilityTree {
    private var byNode: [UUID: ERDiagramNodeElement] = [:]
    private var ordered: [ERDiagramNodeElement] = []
    private var isStale = true

    /// Whether anything has ever asked. Nothing is posted before that: the elements do not exist
    /// yet, so a notification has nowhere to land, and asking for one is itself what builds them.
    private(set) var hasBeenAsked = false

    func invalidate() {
        isStale = true
    }

    func elements(for scene: ERDiagramScene, owner: NSView) -> [ERDiagramNodeElement] {
        hasBeenAsked = true
        guard isStale else { return ordered }
        isStale = false

        let joins = Joins(scene: scene)
        var kept: [UUID: ERDiagramNodeElement] = [:]
        var next: [ERDiagramNodeElement] = []
        for node in scene.nodes {
            guard let rect = scene.nodeRects[node.id] else { continue }
            let element = byNode[node.id] ?? ERDiagramNodeElement()
            element.configure(
                owner: owner,
                node: node,
                rect: rect,
                relationships: joins.description(of: node.tableName)
            )
            kept[node.id] = element
            next.append(element)
        }
        byNode = kept
        ordered = next
        return next
    }

    func element(for nodeId: UUID) -> ERDiagramNodeElement? {
        byNode[nodeId]
    }

    static func summary(of scene: ERDiagramScene) -> String {
        String(
            format: String(localized: "%1$d tables, %2$d relationships"),
            scene.nodes.count,
            scene.edges.count
        )
    }

    /// What each table is joined to, so the shape of the schema is reachable without an element per
    /// relationship: a connector carries no text of its own, and a list of them read in isolation
    /// says nothing a table's own entry cannot.
    ///
    /// Built once per rebuild rather than per table, because asking every table to scan every edge
    /// is quadratic on a schema large enough to need this.
    struct Joins {
        private var references: [String: Set<String>] = [:]
        private var referencedBy: [String: Set<String>] = [:]
        private var related: [String: Set<String>] = [:]
        private var selfReferencing: Set<String> = []

        init(scene: ERDiagramScene) {
            for edge in scene.edges {
                guard edge.fromTable != edge.toTable else {
                    selfReferencing.insert(edge.fromTable)
                    continue
                }
                // A collapsed junction becomes one synthetic edge between the two parents, and that
                // relationship is symmetric: the hidden table owns both foreign keys, so neither
                // parent references the other.
                if edge.cardinality == .manyToMany {
                    related[edge.fromTable, default: []].insert(edge.toTable)
                    related[edge.toTable, default: []].insert(edge.fromTable)
                    continue
                }
                references[edge.fromTable, default: []].insert(edge.toTable)
                referencedBy[edge.toTable, default: []].insert(edge.fromTable)
            }
        }

        func description(of table: String) -> String? {
            var parts: [String] = []
            if let names = list(references[table]) {
                parts.append(String(format: String(localized: "references %@"), names))
            }
            if let names = list(referencedBy[table]) {
                parts.append(String(format: String(localized: "referenced by %@"), names))
            }
            if let names = list(related[table]) {
                parts.append(String(format: String(localized: "related to %@"), names))
            }
            if selfReferencing.contains(table) {
                parts.append(String(localized: "references itself"))
            }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }

        private func list(_ names: Set<String>?) -> String? {
            guard let names, !names.isEmpty else { return nil }
            return names.sorted().joined(separator: ", ")
        }
    }
}
