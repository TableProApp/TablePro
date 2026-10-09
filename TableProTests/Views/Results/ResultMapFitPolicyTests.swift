//
//  ResultMapFitPolicyTests.swift
//  TableProTests
//

import AppKit
import MapKit
@testable import TablePro
import Testing

/// The result Map's 32pt margin shows 13 km around a point in an 80pt field and 1 km in a 320pt
/// one, measured. These pin the margins a field gets instead, and that the result Map kept its own.
struct ResultMapFitPolicyTests {
    private static let point = MKMapSize(width: 0, height: 0)
    private static let shape = MKMapSize(width: 1_200, height: 800)

    private func edges(_ insets: NSEdgeInsets) -> [CGFloat] {
        [insets.top, insets.left, insets.bottom, insets.right]
    }

    private func padding(
        _ policy: ResultMapCoordinator.FitPolicy,
        extent: MKMapSize,
        holdsPoints: Bool
    ) -> [CGFloat] {
        edges(ResultMapCoordinator.edgePadding(for: policy, extent: extent, holdsPoints: holdsPoints))
    }

    @Test("The result Map keeps 32 points on every edge, whatever it fits")
    func resultPaddingIsUnchanged() {
        for extent in [Self.point, Self.shape, MKMapSize(width: 500, height: 0)] {
            for holdsPoints in [true, false] {
                #expect(padding(.result, extent: extent, holdsPoints: holdsPoints) == [32, 32, 32, 32])
            }
        }
    }

    @Test("A coordinator made without a policy fits as the result Map does")
    @MainActor
    func defaultPolicyIsResult() {
        #expect(ResultMapCoordinator(onSelect: { _ in }).fitPolicy == .result)
        #expect(ResultMapCoordinator(fitPolicy: .field, onSelect: { _ in }).fitPolicy == .field)
    }

    @Test("A lone point in a field gets no edge padding, because its 400 m already is the margin")
    func fieldPointHasNoPadding() {
        #expect(padding(.field, extent: Self.point, holdsPoints: true) == [0, 0, 0, 0])
    }

    @Test("A shape in a field gets 16 points on every edge")
    func fieldShapePadding() {
        #expect(padding(.field, extent: Self.shape, holdsPoints: false) == [16, 16, 16, 16])
    }

    @Test("Points beside other shapes get 44 points on top, for the marker standing on the top edge")
    func fieldPointsNeedRoomOnTop() {
        #expect(padding(.field, extent: Self.shape, holdsPoints: true) == [44, 16, 16, 16])
    }

    @Test("A line that runs due east or due north is a shape, not a point")
    func flatLineIsNotAPoint() {
        #expect(padding(.field, extent: MKMapSize(width: 1_200, height: 0), holdsPoints: false) == [16, 16, 16, 16])
        #expect(padding(.field, extent: MKMapSize(width: 0, height: 800), holdsPoints: false) == [16, 16, 16, 16])
        #expect(padding(.field, extent: MKMapSize(width: 1_200, height: 0), holdsPoints: true) == [44, 16, 16, 16])
    }

    @Test("A new value is fitted even when the caller asked for no fit")
    func newProjectionChangesTheFitKey() {
        let first = GeometryFieldMapCanvas.fitKey(projectionToken: 1, fitToken: 0)
        #expect(GeometryFieldMapCanvas.fitKey(projectionToken: 2, fitToken: 0) != first)
        #expect(GeometryFieldMapCanvas.fitKey(projectionToken: 1, fitToken: 1) != first)
        #expect(GeometryFieldMapCanvas.fitKey(projectionToken: 1, fitToken: 0) == first)
    }
}
