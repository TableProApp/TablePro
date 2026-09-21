//
//  ChatContentWidth.swift
//  TablePro
//

import SwiftUI

/// How wide a conversation lays itself out.
///
/// Every view in the chat fills what it is given, which is right for the trailing pane it was
/// measured in at 270pt and wrong for Agent mode, where the same view is the window's content column
/// and a line ran the whole width of the window. The two are one view with two widths rather than two
/// views: the transcript, the composer draft and the provider picker belong to the session, and a
/// second chat surface would be a second place for each of them to drift.
internal enum ChatContentWidth: Equatable {
    /// Fills its column, which is the trailing assistant's shape.
    case pane
    /// A centred column of a comfortable reading measure, with the rest of the width left as margin.
    case reading

    /// 720pt, which holds about 90 characters at the app's body size: the measure typographers put a
    /// column at, and the one Mail, Notes and Xcode's documentation settle on.
    internal var maxWidth: CGFloat? {
        switch self {
        case .pane: nil
        case .reading: 720
        }
    }
}

internal extension View {
    /// Caps the view at the width's measure and centres it in what is left. A `.pane` conversation is
    /// unchanged by it, so the two widths take the same path through every view.
    func chatColumn(_ width: ChatContentWidth) -> some View {
        frame(maxWidth: width.maxWidth ?? .infinity)
            .frame(maxWidth: .infinity)
    }
}
