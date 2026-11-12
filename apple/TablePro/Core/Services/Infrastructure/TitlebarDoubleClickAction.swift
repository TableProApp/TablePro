//
//  TitlebarDoubleClickAction.swift
//  TablePro
//

import Foundation

/// What a double-click on a window's titlebar does, as System Settings > Desktop & Dock sets it.
internal enum TitlebarDoubleClickAction: Equatable {
    case zoom
    case minimize
    case none

    /// `setting` is the current preference; `minimizesLegacy` is the checkbox older macOS versions wrote, which still
    /// decides when the current preference was never set.
    internal init(setting: String?, minimizesLegacy: Bool) {
        switch setting {
        case "Minimize": self = .minimize
        case "None": self = .none
        case nil: self = minimizesLegacy ? .minimize : .zoom
        default: self = .zoom
        }
    }

    /// macOS owns these keys in the global domain, which only the standard defaults read.
    internal static var current: TitlebarDoubleClickAction {
        let defaults = UserDefaults.standard
        return TitlebarDoubleClickAction(
            setting: defaults.string(forKey: "AppleActionOnDoubleClick"),
            minimizesLegacy: defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick")
        )
    }
}
