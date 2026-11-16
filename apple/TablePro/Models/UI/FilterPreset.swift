import Foundation

struct FilterPreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var filters: [TableFilter]
    var createdAt: Date

    init(id: UUID = UUID(), name: String, filters: [TableFilter], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.filters = filters
        self.createdAt = createdAt
    }
}

@MainActor final class FilterPresetStorage {
    static let shared = FilterPresetStorage()

    private static let presetsKey = JSONDefaultsKey<[FilterPreset]>("com.TablePro.filter.presets")
    private let defaults = AppStorageEnvironment.shared.defaults

    private var cachedPresets: [FilterPreset]?

    private init() {}

    func savePreset(_ preset: FilterPreset) {
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

        saveAllPresets(presets)
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

    func deletePreset(_ preset: FilterPreset) {
        var presets = loadAllPresets()
        presets.removeAll { $0.id == preset.id }
        saveAllPresets(presets)
    }

    func deleteAllPresets() {
        defaults.removeValue(for: Self.presetsKey)
        cachedPresets = nil
    }

    func renamePreset(_ preset: FilterPreset, to newName: String) {
        var updatedPreset = preset
        updatedPreset.name = newName
        savePreset(updatedPreset)
    }

    // MARK: - Private

    private func saveAllPresets(_ presets: [FilterPreset]) {
        do {
            try defaults.write(presets, to: Self.presetsKey)
        } catch {
            return
        }
        cachedPresets = presets.sorted { $0.createdAt > $1.createdAt }
    }
}
