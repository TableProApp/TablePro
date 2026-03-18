import Foundation

/// Represents a saved filter preset with a name and filters
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

/// Storage manager for filter presets
final class FilterPresetStorage {
    static let shared = FilterPresetStorage()

    private let presetsKey = "com.TablePro.filter.presets"
    private let defaults = UserDefaults.standard

    /// Cached presets to avoid repeated UserDefaults read + JSON decode
    private var cachedPresets: [FilterPreset]?

    private init() {}

    /// Save a new preset
    func savePreset(_ preset: FilterPreset) {
        var presets = loadAllPresets()

        // Replace if preset with same name exists
        if let index = presets.firstIndex(where: { $0.name == preset.name }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }

        saveAllPresets(presets)
    }

    /// Load all saved presets (cached after first read)
    func loadAllPresets() -> [FilterPreset] {
        if let cached = cachedPresets { return cached }

        guard let data = defaults.data(forKey: presetsKey),
              let presets = try? JSONDecoder().decode([FilterPreset].self, from: data) else {
            cachedPresets = []
            return []
        }
        let sorted = presets.sorted { $0.createdAt > $1.createdAt }
        cachedPresets = sorted
        return sorted
    }

    /// Delete a preset
    func deletePreset(_ preset: FilterPreset) {
        var presets = loadAllPresets()
        presets.removeAll { $0.id == preset.id }
        saveAllPresets(presets)
    }

    /// Delete all presets
    func deleteAllPresets() {
        defaults.removeObject(forKey: presetsKey)
        cachedPresets = nil
    }

    /// Rename a preset
    func renamePreset(_ preset: FilterPreset, to newName: String) {
        var updatedPreset = preset
        updatedPreset.name = newName
        savePreset(updatedPreset)
    }

    // MARK: - Private

    private func saveAllPresets(_ presets: [FilterPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: presetsKey)
        cachedPresets = presets.sorted { $0.createdAt > $1.createdAt }
    }
}
