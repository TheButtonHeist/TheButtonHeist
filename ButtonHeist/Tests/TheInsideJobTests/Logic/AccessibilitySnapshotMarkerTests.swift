#if canImport(UIKit)
import AccessibilitySnapshotModel
import ButtonHeistTestSupport
import Foundation
import XCTest

@testable import TheInsideJob
import TheScore

final class AccessibilitySnapshotMarkerTests: XCTestCase {
    func testMarkersContainOnlyOnscreenElementsInTraversalOrder() throws {
        let interface = makeTestInterface(nodes: [
            .parsedElement(.make(label: "First visible", visibility: .onscreen), actions: []),
            .parsedElement(.make(label: "Offscreen", visibility: .offscreen), actions: []),
            .parsedElement(.make(label: "Second visible", visibility: .onscreen), actions: []),
        ], timestamp: Date())

        let markers = TheBrains.accessibilitySnapshotMarkers(in: interface)
        let numberedLabels = markers.enumerated().map { index, marker in
            "\(index + 1): \(marker.label ?? "")"
        }

        XCTAssertEqual(numberedLabels, ["1: First visible", "2: Second visible"])
    }
}
#endif
