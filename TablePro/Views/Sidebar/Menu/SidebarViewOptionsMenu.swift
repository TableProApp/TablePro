//
//  SidebarViewOptionsMenu.swift
//  TablePro
//

import Foundation

/// How the object list draws itself: icons, comments and row height.
///
/// These settle the sidebar, not the clicked object, so they are not on an object row's contextual
/// menu. The HIG asks a contextual menu to carry commands relevant to the item the pointer is over,
/// and this was appended to every menu the object tree produced, including every table, view,
/// routine, trigger and Redis key. It now has one home the pointer can always reach, the control in
/// the sidebar's filter row, and one fallback on the empty-area menu.
///
/// Both read this, so the two can never list different options or report a different state.
internal enum SidebarViewOptionsMenu {
    internal static var title: String {
        String(localized: "View Options")
    }

    internal static func sections(_ context: DatabaseTreeMenuContext) -> [DatabaseTreeMenuSection] {
        sections(
            showObjectIcons: context.showObjectIcons,
            showObjectComments: context.showObjectComments,
            rowSize: context.rowSize
        )
    }

    internal static func sections(
        showObjectIcons: Bool,
        showObjectComments: Bool,
        rowSize: SidebarRowSizePreference
    ) -> [DatabaseTreeMenuSection] {
        [
            DatabaseTreeMenuSection([
                .command(SidebarMenuEntry(
                    title: String(localized: "Icons"),
                    command: .toggleObjectIcons,
                    isOn: showObjectIcons
                )),
                .command(SidebarMenuEntry(
                    title: String(localized: "Comments"),
                    command: .toggleObjectComments,
                    isOn: showObjectComments
                ))
            ]),
            DatabaseTreeMenuSection(SidebarRowSizePreference.allCases.map { size in
                .command(SidebarMenuEntry(
                    title: size.title,
                    command: .setRowSize(size),
                    isOn: rowSize == size
                ))
            })
        ]
    }

    /// Applied here rather than by each menu that offers these, so a fourth option added above
    /// cannot work from the empty-area menu and do nothing from the filter row's control.
    /// Returns false for a command that is not one of these, which is what lets the object tree's
    /// own dispatch hand every command to this first.
    @MainActor
    internal static func apply(_ command: SidebarMenuCommand) -> Bool {
        switch command {
        case .toggleObjectIcons:
            AppSettingsManager.shared.general.showObjectIcons.toggle()
        case .toggleObjectComments:
            AppSettingsManager.shared.general.showObjectComments.toggle()
        case .setRowSize(let size):
            AppSettingsManager.shared.general.sidebarRowSize = size
        default:
            return false
        }
        return true
    }

    /// The control in the filter row is sidebar chrome that outlives a connection switch, so it
    /// reads the settings directly rather than through whichever tree happens to be mounted.
    @MainActor
    internal static func currentSections() -> [DatabaseTreeMenuSection] {
        let settings = AppSettingsManager.shared.general
        return sections(
            showObjectIcons: settings.showObjectIcons,
            showObjectComments: settings.showObjectComments,
            rowSize: settings.sidebarRowSize
        )
    }
}
