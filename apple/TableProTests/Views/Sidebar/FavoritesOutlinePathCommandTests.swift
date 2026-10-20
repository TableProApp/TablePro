//
//  FavoritesOutlinePathCommandTests.swift
//  TableProTests
//

import AppKit
import Testing

@testable import TablePro

@MainActor
struct FavoritesOutlinePathCommandTests {
    private final class Handler: FavoritesOutlineKeyHandling {
        var selectedFilePath: FavoriteFilePath?
        var performed: [FavoritesMenuCommand] = []

        func performPrimaryAction() {}
        func performDelete() {}

        func performMenuCommand(_ command: FavoritesMenuCommand) {
            performed.append(command)
        }
    }

    private func outline(selecting path: FavoriteFilePath?) -> (FavoritesNSOutlineView, Handler) {
        let handler = Handler()
        handler.selectedFilePath = path
        let view = FavoritesNSOutlineView()
        view.favoritesCoordinator = handler
        return (view, handler)
    }

    private func validates(_ view: FavoritesNSOutlineView, _ action: Selector) -> Bool {
        view.validateUserInterfaceItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }

    @Test("A selected linked file enables both commands and copies each path")
    func linkedFileCopiesBothPaths() {
        let (view, handler) = outline(selecting: FavoriteFilePath(
            absolute: "/tmp/queries/reports/daily.sql",
            relative: "reports/daily.sql"
        ))

        #expect(validates(view, #selector(FavoritesNSOutlineView.copyPath(_:))))
        #expect(validates(view, #selector(FavoritesNSOutlineView.copyRelativePath(_:))))

        view.copyPath(nil)
        view.copyRelativePath(nil)
        #expect(handler.performed == [
            .copyPath("/tmp/queries/reports/daily.sql"),
            .copyRelativePath("reports/daily.sql")
        ])
    }

    @Test("A selected linked folder root enables Copy Path only")
    func folderRootHasNoRelativePath() {
        let (view, handler) = outline(selecting: FavoriteFilePath(absolute: "/tmp/queries", relative: nil))

        #expect(validates(view, #selector(FavoritesNSOutlineView.copyPath(_:))))
        #expect(!validates(view, #selector(FavoritesNSOutlineView.copyRelativePath(_:))))

        view.copyRelativePath(nil)
        #expect(handler.performed.isEmpty)
    }

    @Test("A selection with no file behind it disables both commands")
    func noFileDisablesBoth() {
        let (view, handler) = outline(selecting: nil)

        #expect(!validates(view, #selector(FavoritesNSOutlineView.copyPath(_:))))
        #expect(!validates(view, #selector(FavoritesNSOutlineView.copyRelativePath(_:))))

        view.copyPath(nil)
        #expect(handler.performed.isEmpty)
    }
}
