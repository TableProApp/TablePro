//
//  SafeModeStatus.swift
//  TablePro
//

import Foundation

/// The Safe Mode level a connection is running at, and the floor holding it there.
///
/// Everything that offers the level reads this one value: the Database menu's list, the toolbar
/// control's list and its tooltip, the validation of each entry, and the write the choice ends in.
/// Two readings used to disagree. The list, its validation and the write's own guard asked the
/// connection's own floor, which cannot see Agent mode, while the level in force came from the
/// floor that can, so a weaker level picked in Agent mode was stored and then held at Alert, and
/// nothing said why.
internal struct SafeModeStatus: Equatable {
    internal let level: SafeModeLevel
    internal let floor: SafeModeFloor?

    /// The levels on offer: the floor's own and every stricter one. A level below the floor is left
    /// out rather than listed dimmed, the way the connection form's picker leaves it out, and the
    /// floor's reason is printed under the list instead.
    internal var offeredLevels: [SafeModeLevel] {
        SafeModeFloor.levels(allowedBy: floor)
    }

    internal func offers(_ candidate: SafeModeLevel) -> Bool {
        floor?.allows(candidate) ?? true
    }

    /// Whether choosing `candidate` is taken as the user's new level.
    ///
    /// Only a choice that moves the level in force is. One below the floor is refused rather than
    /// stored for later: storing it changed nothing on screen, since the floor raised it straight
    /// back, and handed a level the user never saw take effect back to them when the floor lifted.
    /// Choosing the level already in force is refused too, because under a floor that level can be
    /// the floor's rather than the user's, and writing it would replace the one they chose.
    internal func accepts(_ candidate: SafeModeLevel) -> Bool {
        candidate != level && offers(candidate)
    }

    /// What the toolbar control says it is set to, and when something holds it there, why. The
    /// glyph alone cannot carry either: `lock` and `lock.open` differ by a few pixels, and VoiceOver
    /// reads no image at all.
    internal var toolTip: String {
        let current = String(format: String(localized: "Safe Mode: %@"), level.displayName)
        guard let floor else { return current }
        return current + "\n" + floor.explanation
    }
}
