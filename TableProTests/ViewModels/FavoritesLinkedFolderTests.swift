//
//  FavoritesLinkedFolderTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// Adding a folder that is already linked used to be refused outright, which pointed the user at a
/// list the folder was invisible in whenever it had been disabled.
@Suite("Linked SQL folder outcome")
@MainActor
struct FavoritesLinkedFolderTests {
    private func makeViewModel() -> FavoritesSidebarViewModel {
        FavoritesSidebarViewModel(connectionId: UUID())
    }

    private func clearStoredFolders() {
        for folder in LinkedSQLFolderStorage.shared.loadFolders() {
            LinkedSQLFolderStorage.shared.removeFolder(folder)
        }
    }

    @Test("A folder that is not linked yet is added")
    func addsANewFolder() {
        clearStoredFolders()
        defer { clearStoredFolders() }
        let url = URL(fileURLWithPath: "/tmp/tablepro-linked-\(UUID().uuidString)")

        #expect(makeViewModel().addLinkedFolder(at: url) == .added)
    }

    @Test("Choosing a disabled folder again re-enables it instead of refusing")
    func reEnablesADisabledFolder() throws {
        clearStoredFolders()
        defer { clearStoredFolders() }
        let viewModel = makeViewModel()
        let url = URL(fileURLWithPath: "/tmp/tablepro-linked-\(UUID().uuidString)")
        #expect(viewModel.addLinkedFolder(at: url) == .added)

        let stored = try #require(LinkedSQLFolderStorage.shared.loadFolders().last)
        viewModel.setLinkedFolder(stored, enabled: false)

        #expect(viewModel.addLinkedFolder(at: url) == .reEnabled)
        #expect(LinkedSQLFolderStorage.shared.loadFolders().last?.isEnabled == true)
    }

    @Test("A folder that is already linked and enabled reports itself by name")
    func reportsAnAlreadyLinkedFolder() {
        clearStoredFolders()
        defer { clearStoredFolders() }
        let viewModel = makeViewModel()
        let name = "tablepro-linked-\(UUID().uuidString)"
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        #expect(viewModel.addLinkedFolder(at: url) == .added)

        #expect(viewModel.addLinkedFolder(at: url) == .alreadyLinked(name: name))
    }

    @Test("Disabling a folder leaves it stored, so its row and its Enable command survive")
    func disablingKeepsTheFolder() throws {
        clearStoredFolders()
        defer { clearStoredFolders() }
        let viewModel = makeViewModel()
        let url = URL(fileURLWithPath: "/tmp/tablepro-linked-\(UUID().uuidString)")
        viewModel.addLinkedFolder(at: url)
        let stored = try #require(LinkedSQLFolderStorage.shared.loadFolders().last)

        viewModel.setLinkedFolder(stored, enabled: false)

        let after = try #require(LinkedSQLFolderStorage.shared.loadFolders().last)
        #expect(after.id == stored.id)
        #expect(after.isEnabled == false)
    }

    @Test("Removing a folder takes it out of storage")
    func removingDropsTheFolder() throws {
        clearStoredFolders()
        defer { clearStoredFolders() }
        let viewModel = makeViewModel()
        let url = URL(fileURLWithPath: "/tmp/tablepro-linked-\(UUID().uuidString)")
        viewModel.addLinkedFolder(at: url)
        let stored = try #require(LinkedSQLFolderStorage.shared.loadFolders().last)

        viewModel.removeLinkedFolder(stored)

        #expect(!LinkedSQLFolderStorage.shared.loadFolders().contains { $0.id == stored.id })
    }
}
