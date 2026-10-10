#if canImport(UIKit)
import UIKit
import XCTest

@testable import AccessibilitySnapshotParser
@testable import TheInsideJob

@MainActor
final class TheVaultInventoryTests: XCTestCase {
    private var vault: TheVault!

    override func setUp() async throws {
        try await super.setUp()
        vault = TheVault(tripwire: TheTripwire())
    }

    override func tearDown() async throws {
        vault = nil
        try await super.tearDown()
    }

    func testInventoryEnumerationWithZeroBudgetAndEmptyInventoryRequestsNothing() {
        let path = TreePath([0])
        let scrollView = RecordingInventoryScrollView(reportedCount: 0)

        let result = vault.enumerateOffscreenScrollInventory(
            objectsByPath: [:], scrollViewsByPath: [path: scrollView], budget: 0
        )

        XCTAssertEqual(scrollView.requestedIndices, [])
        XCTAssertEqual(scrollView.countRequestCount, 1)
        XCTAssertEqual(result.reportedCountsByContainerPath[path]!, 0)
        XCTAssertEqual(result.attemptedCount, 0)
        XCTAssertEqual(result.knownUnattemptedCount, 0)
    }

    func testInventoryEnumerationWithZeroBudgetAndNonemptyInventoryRequestsNothing() {
        let path = TreePath([0])
        let scrollView = RecordingInventoryScrollView(reportedCount: 4)
        let result = vault.enumerateOffscreenScrollInventory(
            objectsByPath: [:], scrollViewsByPath: [path: scrollView], budget: 0
        )

        XCTAssertEqual(scrollView.requestedIndices, [])
        XCTAssertEqual(scrollView.countRequestCount, 1)
        XCTAssertEqual(result.attemptedCount, 0)
        XCTAssertEqual(result.knownUnattemptedCount, 4)
    }

    func testInventoryEnumerationBelowBudgetRequestsEveryReportedIndex() {
        let path = TreePath([0])
        let scrollView = RecordingInventoryScrollView(reportedCount: 2)
        let result = vault.enumerateOffscreenScrollInventory(
            objectsByPath: [:], scrollViewsByPath: [path: scrollView], budget: 3
        )

        XCTAssertEqual(scrollView.requestedIndices, [0, 1])
        XCTAssertEqual(scrollView.countRequestCount, 1)
        XCTAssertEqual(result.attemptedCount, 2)
        XCTAssertEqual(result.knownUnattemptedCount, 0)
    }

    func testInventoryEnumerationAtBudgetRequestsEveryReportedIndex() {
        let path = TreePath([0])
        let scrollView = RecordingInventoryScrollView(reportedCount: 3)
        let result = vault.enumerateOffscreenScrollInventory(
            objectsByPath: [:], scrollViewsByPath: [path: scrollView], budget: 3
        )

        XCTAssertEqual(scrollView.requestedIndices, [0, 1, 2])
        XCTAssertEqual(scrollView.countRequestCount, 1)
        XCTAssertEqual(result.attemptedCount, 3)
        XCTAssertEqual(result.knownUnattemptedCount, 0)
    }

    func testInventoryEnumerationAboveBudgetStopsBeforeNextRequest() {
        let path = TreePath([0])
        let scrollView = RecordingInventoryScrollView(reportedCount: 4)
        let result = vault.enumerateOffscreenScrollInventory(
            objectsByPath: [:], scrollViewsByPath: [path: scrollView], budget: 3
        )

        XCTAssertEqual(scrollView.requestedIndices, [0, 1, 2])
        XCTAssertEqual(scrollView.countRequestCount, 1)
        XCTAssertEqual(result.attemptedCount, 3)
        XCTAssertEqual(result.knownUnattemptedCount, 1)
    }

    func testInventoryEnumerationConsumesBudgetForEveryUnsuccessfulAttempt() {
        struct UnsupportedInventoryValue {}

        let path = TreePath([0])
        let representedObject = UILabel()
        let scrollView = RecordingInventoryScrollView(
            reportedCount: 5,
            elementAtIndex: { index in
                switch index {
                case 0: representedObject
                case 1: nil
                case 2: UnsupportedInventoryValue()
                case 3: NSObject()
                default: UIAccessibilityElement(accessibilityContainer: NSObject())
                }
            }
        )
        let result = vault.enumerateOffscreenScrollInventory(
            objectsByPath: [TreePath([9]): representedObject],
            scrollViewsByPath: [path: scrollView],
            budget: 4
        )

        XCTAssertEqual(scrollView.requestedIndices, [0, 1, 2, 3])
        XCTAssertEqual(result.attemptedCount, 4)
        XCTAssertEqual(result.knownUnattemptedCount, 1)
    }

    func testInventoryEnumerationSharesOneBudgetAcrossContainersInPathOrder() {
        let firstPath = TreePath([0])
        let secondPath = TreePath([1])
        let first = RecordingInventoryScrollView(reportedCount: 2)
        let second = RecordingInventoryScrollView(reportedCount: 2)
        let result = vault.enumerateOffscreenScrollInventory(
            objectsByPath: [:], scrollViewsByPath: [secondPath: second, firstPath: first], budget: 3
        )

        XCTAssertEqual(first.requestedIndices, [0, 1])
        XCTAssertEqual(second.requestedIndices, [0])
        XCTAssertEqual(first.countRequestCount, 1)
        XCTAssertEqual(second.countRequestCount, 1)
        XCTAssertEqual(result.attemptedCount, 3)
        XCTAssertEqual(result.knownUnattemptedCount, 1)
    }

    func testInventoryEnumerationFarAboveBudgetDoesNotScaleElementRequestsWithReportedCount() {
        let path = TreePath([0])
        let scrollView = RecordingInventoryScrollView(reportedCount: 1_000_000)
        let result = vault.enumerateOffscreenScrollInventory(
            objectsByPath: [:], scrollViewsByPath: [path: scrollView], budget: 2
        )

        XCTAssertEqual(scrollView.requestedIndices, [0, 1])
        XCTAssertEqual(scrollView.countRequestCount, 1)
        XCTAssertEqual(result.attemptedCount, 2)
        XCTAssertEqual(result.knownUnattemptedCount, 999_998)
    }

    func testInventoryEnumerationPreservesUnknownCountWithoutElementRequests() {
        let path = TreePath([0])
        let scrollView = RecordingInventoryScrollView(reportedCount: NSNotFound)
        let result = vault.enumerateOffscreenScrollInventory(
            objectsByPath: [:], scrollViewsByPath: [path: scrollView], budget: 3
        )

        XCTAssertEqual(scrollView.requestedIndices, [])
        XCTAssertEqual(scrollView.countRequestCount, 1)
        guard let reportedCount = result.reportedCountsByContainerPath[path] else {
            return XCTFail("Expected an admitted inventory count")
        }
        XCTAssertNil(reportedCount)
        XCTAssertEqual(result.knownUnattemptedCount, 0)
    }

    func testCaptureTreeReusesInventoryEnumerationCountSnapshot() throws {
        let path = TreePath([0])
        let scrollView = RecordingInventoryScrollView(reportedCount: 2)
        scrollView.contentSize = CGSize(width: 320, height: 1_600)
        let enumeration = vault.enumerateOffscreenScrollInventory(
            objectsByPath: [:], scrollViewsByPath: [path: scrollView], budget: 0
        )
        let capture = TheVault.CaptureTree(
            hierarchy: [.container(makeScrollableContainer(), children: [])],
            containerObjectsByPath: [path: scrollView],
            scrollViewsByPath: [path: scrollView],
            inventoryEnumeration: enumeration
        )

        let observation = TheVault.buildObservation(from: capture)

        XCTAssertEqual(scrollView.countRequestCount, 1)
        XCTAssertEqual(
            try XCTUnwrap(observation.tree.containers[path]?.scrollInventory).totalElementCount,
            2
        )
    }

    private func makeScrollableContainer() -> AccessibilityContainer {
        AccessibilityContainer(
            type: .none,
            scrollableContentSize: AccessibilitySize(width: 320, height: 1_600),
            frame: AccessibilityRect(x: 0, y: 0, width: 320, height: 400)
        )
    }
}

@MainActor
private final class RecordingInventoryScrollView: UIScrollView {
    private let reportedCount: Int
    private let elementAtIndex: (Int) -> Any?
    private(set) var countRequestCount = 0
    private(set) var requestedIndices: [Int] = []

    init(reportedCount: Int, elementAtIndex: @escaping (Int) -> Any? = { _ in nil }) {
        self.reportedCount = reportedCount
        self.elementAtIndex = elementAtIndex
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func accessibilityElementCount() -> Int {
        countRequestCount += 1
        return reportedCount
    }

    override func accessibilityElement(at index: Int) -> Any? {
        requestedIndices.append(index)
        return elementAtIndex(index)
    }
}

#endif
