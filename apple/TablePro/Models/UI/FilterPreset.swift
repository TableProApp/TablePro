import Foundation

struct FilterPreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var filters: [TableFilter]
    // Absent in presets saved before it was kept; loading one leaves the tab's mode as it is.
    var logicMode: FilterLogicMode?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        filters: [TableFilter],
        logicMode: FilterLogicMode? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.filters = filters
        self.logicMode = logicMode
        self.createdAt = createdAt
    }
}

@MainActor final class FilterPresetStorage {
    static let shared = FilterPresetStorage()

    private static let presetsKey = JSONDefaultsKey<[FilterPreset]>("com.TablePro.filter.presets")
    private let defaults = AppStorageEnvironment.shared.defaults

    private var cachedPresets: [FilterPreset]?

    private init() {}

    func savePreset(_ preset: FilterPreset) throws {
        var presets = loadAllPresets()

        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            var adjusted = preset
            let existingNames = Set(presets.map(\.name))
            if existingNames.contains(adjusted.name) {
                adjusted.name = Self.uniqueName(for: adjusted.name, existingNames: existingNames)
            }
            presets.append(adjusted)
        }

        try saveAllPresets(presets)
    }

    private static func uniqueName(for base: String, existingNames: Set<String>) -> String {
        var counter = 2
        var candidate = "\(base) (\(counter))"
        while existingNames.contains(candidate) {
            counter += 1
            candidate = "\(base) (\(counter))"
        }
        return candidate
    }

    func loadAllPresets() -> [FilterPreset] {
        if let cached = cachedPresets { return cached }

        guard let presets = defaults.read(Self.presetsKey).value else {
            cachedPresets = []
            return []
        }
        let sorted = presets.sorted { $0.createdAt > $1.createdAt }
        cachedPresets = sorted
        return sorted
    }

    func deletePreset(_ preset: FilterPreset) throws {
        var presets = loadAllPresets()
        presets.removeAll { $0.id == preset.id }
        try saveAllPresets(presets)
    }

    func deleteAllPresets() {
        defaults.removeValue(for: Self.presetsKey)
        cachedPresets = nil
    }

    private func saveAllPresets(_ presets: [FilterPreset]) throws {
        try defaults.write(presets, to: Self.presetsKey)
        cachedPresets = presets.sorted { $0.createdAt > $1.createdAt }
    }
}
