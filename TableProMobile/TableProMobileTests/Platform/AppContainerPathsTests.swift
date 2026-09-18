import Foundation
@testable import TableProMobile
import Testing

@Suite("App container paths")
struct AppContainerPathsTests {
    private let family = "/var/mobile/Containers/Data/Application"
    private let current = "11111111-1111-1111-1111-111111111111"
    private let earlier = "22222222-2222-2222-2222-222222222222"
    private let otherInstall = "33333333-3333-3333-3333-333333333333"
    private let history: AppContainerHistory

    init() {
        history = AppContainerHistory(suiteName: "com.TablePro.tests.AppContainers.\(UUID().uuidString)")
    }

    private var documents: String { "\(family)/\(current)/Documents" }

    private func paths(currentContainer: String? = nil) -> AppContainerPaths {
        let containerId = currentContainer ?? current
        return AppContainerPaths(
            documentsDirectory: URL(fileURLWithPath: "\(family)/\(containerId)/Documents"),
            history: history
        )
    }

    @Test("A path in the current container resolves to itself, with or without the private prefix")
    func currentContainerResolvesInPlace() {
        let container = paths()

        #expect(
            container.resolve("\(documents)/notes.db")
                == .inThisInstall(URL(fileURLWithPath: "\(documents)/notes.db"))
        )
        #expect(
            container.resolve("/private\(documents)/notes.db")
                == .inThisInstall(URL(fileURLWithPath: "/private\(documents)/notes.db"))
        )
    }

    @Test("A Documents path in a container this install recorded is re-rooted into today's Documents")
    func recordedContainerIsReRooted() {
        history.record(earlier)
        let container = paths()

        #expect(
            container.resolve("\(family)/\(earlier)/Documents/notes.db")
                == .inThisInstall(URL(fileURLWithPath: "\(documents)/notes.db"))
        )
        #expect(
            container.resolve("/private\(family)/\(earlier)/Documents/archive/2024.db")
                == .inThisInstall(URL(fileURLWithPath: "\(documents)/archive/2024.db"))
        )
    }

    @Test("A container this install never recorded belongs to another device or app and is not re-rooted")
    func unrecordedContainerIsNotOnThisDevice() {
        history.record(earlier)
        let container = paths()

        #expect(container.resolve("\(family)/\(otherInstall)/Documents/notes.db") == .notOnThisDevice)
        #expect(container.resolve("\(family)/\(earlier)/Library/notes.db") == .notOnThisDevice)
        #expect(container.resolve("\(family)/\(earlier)/Documents") == .notOnThisDevice)
    }

    @Test("Relative, home-relative, empty and traversing paths are never resolved against this device")
    func unresolvablePathsAreNotOnThisDevice() {
        history.record(earlier)
        let container = paths()

        #expect(container.resolve("notes.db") == .notOnThisDevice)
        #expect(container.resolve("~/notes.db") == .notOnThisDevice)
        #expect(container.resolve("") == .notOnThisDevice)
        #expect(container.resolve("\(documents)/../secret.db") == .notOnThisDevice)
        #expect(container.resolve("\(family)/\(earlier)/Documents/../../\(otherInstall)/x.db") == .notOnThisDevice)
    }

    @Test("A path outside every app container is kept as it is")
    func pathOutsideContainersIsKept() {
        let container = paths()

        #expect(
            container.resolve("/Users/mac/Documents/app.db")
                == .outsideAppContainers(URL(fileURLWithPath: "/Users/mac/Documents/app.db"))
        )
    }

    @Test("Recording each launch's container lets a later container re-root the earlier one's files")
    func launchesAccumulateContainers() {
        paths(currentContainer: earlier).recordCurrentContainer()
        let afterUpdate = paths()
        afterUpdate.recordCurrentContainer()

        #expect(history.containerIds == [earlier, current])
        #expect(
            afterUpdate.resolve("\(family)/\(earlier)/Documents/notes.db")
                == .inThisInstall(URL(fileURLWithPath: "\(documents)/notes.db"))
        )
        #expect(
            paths(currentContainer: earlier).resolve("\(documents)/notes.db")
                == .inThisInstall(URL(fileURLWithPath: "\(family)/\(earlier)/Documents/notes.db"))
        )
    }

    @Test("An SSH key path follows the same rule and is otherwise left for the tunnel to report")
    func keyPathsFollowTheSameRule() {
        history.record(earlier)
        let container = paths()

        #expect(
            container.localPath(forStoredPath: "\(family)/\(earlier)/Documents/ssh_id_ed25519")
                == "\(documents)/ssh_id_ed25519"
        )
        #expect(
            container.localPath(forStoredPath: "\(family)/\(otherInstall)/Documents/ssh_id_ed25519")
                == "\(family)/\(otherInstall)/Documents/ssh_id_ed25519"
        )
        #expect(container.localPath(forStoredPath: "~/.ssh/id_rsa") == "~/.ssh/id_rsa")
    }

    @Test("Only files below the current Documents count as inside it")
    func documentsMembership() {
        let container = paths()

        #expect(container.isInDocuments(URL(fileURLWithPath: "\(documents)/notes.db")))
        #expect(container.isInDocuments(URL(fileURLWithPath: "/private\(documents)/notes.db")))
        #expect(!container.isInDocuments(URL(fileURLWithPath: documents)))
        #expect(!container.isInDocuments(URL(fileURLWithPath: "\(family)/\(earlier)/Documents/notes.db")))
    }
}
