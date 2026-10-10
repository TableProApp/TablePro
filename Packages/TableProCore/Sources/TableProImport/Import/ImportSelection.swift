import Foundation

public struct ImportSelection: Sendable, Equatable {
    /// Tunnel commands and startup SQL run on every connect, so a file brings them only on request.
    public var keepsCommands = false
    private var selected: Set<BundleRef> = []
    /// Kept across uncheck, so re-checking a row restores what the user picked.
    private var chosen: [BundleRef: ConnectionResolution] = [:]
    private var queryOverrides: [BundleRef: Bool] = [:]

    public static func defaults(for preview: ImportPreview) -> ImportSelection {
        var selection = ImportSelection()
        for row in preview.connections {
            if let first = row.resolutions.first {
                selection.chosen[row.ref] = first
            }
            if row.isSelectedByDefault {
                selection.selected.insert(row.ref)
            }
        }
        return selection
    }

    public func resolution(for ref: BundleRef) -> ConnectionResolution? {
        guard selected.contains(ref) else { return nil }
        return chosen[ref]
    }

    public mutating func setSelected(_ selected: Bool, connection ref: BundleRef, in preview: ImportPreview) {
        guard selected else {
            self.selected.remove(ref)
            return
        }
        guard let row = preview.connectionRow(ref), let fallback = row.resolutions.first else { return }
        let keepsStored = chosen[ref].map {
            row.resolutions.contains($0) && !isReplaceHeld($0, byOtherThan: ref)
        } ?? false
        if !keepsStored {
            chosen[ref] = fallback
        }
        self.selected.insert(ref)
    }

    @discardableResult
    public mutating func resolve(
        _ ref: BundleRef,
        as resolution: ConnectionResolution,
        in preview: ImportPreview
    ) -> Bool {
        guard let row = preview.connectionRow(ref),
              row.resolutions.contains(resolution),
              !isReplaceHeld(resolution, byOtherThan: ref)
        else {
            return false
        }
        chosen[ref] = resolution
        return true
    }

    public func offeredResolutions(for row: ConnectionRow) -> [ConnectionResolution] {
        row.resolutions.filter { !isReplaceHeld($0, byOtherThan: row.ref) }
    }

    public mutating func setIncluded(_ included: Bool, query ref: BundleRef) {
        queryOverrides[ref] = included
    }

    func queryOverride(_ ref: BundleRef) -> Bool? {
        queryOverrides[ref]
    }

    private func isReplaceHeld(_ resolution: ConnectionResolution, byOtherThan ref: BundleRef) -> Bool {
        guard case .replace(let target) = resolution else { return false }
        return selected.contains { other in
            other != ref && chosen[other] == .replace(target)
        }
    }
}
