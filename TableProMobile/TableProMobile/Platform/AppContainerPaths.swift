import Foundation

nonisolated struct AppContainerPaths: Sendable {
    nonisolated enum Resolution: Equatable, Sendable {
        case inThisInstall(URL)
        case outsideAppContainers(URL)
        case notOnThisDevice
    }

    private struct ContainerReference {
        let containerId: String
        let pathInContainer: ArraySlice<String>
    }

    static let live = AppContainerPaths(documentsDirectory: .documentsDirectory, history: .live)

    let documentsDirectory: URL
    private let history: AppContainerHistory
    private let documentsComponents: [String]

    init(documentsDirectory: URL, history: AppContainerHistory) {
        self.documentsDirectory = documentsDirectory
        self.history = history
        self.documentsComponents = Self.normalizedComponents(of: documentsDirectory.path)
    }

    var currentContainerId: String? {
        guard documentsComponents.count >= 3 else { return nil }
        return documentsComponents[documentsComponents.count - 2]
    }

    func recordCurrentContainer() {
        guard let currentContainerId else { return }
        history.record(currentContainerId)
    }

    func resolve(_ storedPath: String) -> Resolution {
        guard storedPath.hasPrefix("/") else { return .notOnThisDevice }
        let components = Self.normalizedComponents(of: storedPath)
        guard !components.isEmpty, components.allSatisfy(Self.isPlainComponent) else { return .notOnThisDevice }
        guard let reference = containerReference(in: components) else {
            return .outsideAppContainers(URL(fileURLWithPath: storedPath))
        }
        if reference.containerId == currentContainerId {
            return .inThisInstall(URL(fileURLWithPath: storedPath))
        }
        guard history.containerIds.contains(reference.containerId),
              reference.pathInContainer.count > 1,
              reference.pathInContainer.first == documentsComponents.last
        else { return .notOnThisDevice }
        let pathInDocuments = reference.pathInContainer.dropFirst().joined(separator: "/")
        return .inThisInstall(documentsDirectory.appendingPathComponent(pathInDocuments))
    }

    func localPath(forStoredPath storedPath: String) -> String {
        guard case .inThisInstall(let url) = resolve(storedPath) else { return storedPath }
        return url.path
    }

    func isInDocuments(_ url: URL) -> Bool {
        let components = Self.normalizedComponents(of: url.path)
        return components.count > documentsComponents.count && components.starts(with: documentsComponents)
    }

    private func containerReference(in components: [String]) -> ContainerReference? {
        guard documentsComponents.count >= 3 else { return nil }
        let family = documentsComponents.dropLast(2)
        guard components.count > family.count, components.starts(with: family) else { return nil }
        return ContainerReference(
            containerId: components[family.count],
            pathInContainer: components[(family.count + 1)...]
        )
    }

    private static func isPlainComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".."
    }

    private static func normalizedComponents(of path: String) -> [String] {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count > 1, components[0] == "private", ["var", "tmp"].contains(components[1]) else {
            return components
        }
        return Array(components.dropFirst())
    }
}
