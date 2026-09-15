//
//  ObservableObject+MainActorSink.swift
//  TablePro
//

import Combine
import Foundation

internal extension ObservableObject {
    /// Stands in for `withObservationTracking`, which is macOS 14. Two differences the call
    /// sites have to live with, and one this hides.
    ///
    /// `withObservationTracking` woke only for the properties its closure read; this wakes for
    /// any published change on the object, so a caller that needs the old narrowing has to
    /// compare values itself. And `objectWillChange` fires *before* the value lands, which is
    /// why the delivery hops a run-loop turn: a callback that reads the new value would
    /// otherwise read the old one. `withObservationTracking` also fired once and had to be
    /// re-armed by hand; a sink stays armed for as long as its cancellable is held.
    func onMainActorChange(_ body: @escaping () -> Void) -> AnyCancellable {
        objectWillChange
            .receive(on: RunLoop.main)
            .sink { _ in body() }
    }
}
