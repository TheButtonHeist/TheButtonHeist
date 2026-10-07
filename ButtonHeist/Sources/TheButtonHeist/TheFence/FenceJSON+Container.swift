import Foundation

import ThePlans
import TheScore

import AccessibilitySnapshotModel

extension InterfaceContainerProjection: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case label
        case value
        case identifier
        case rowCount
        case columnCount
        case actions
        case contentWidth
        case contentHeight
        case scrollAxis
        case pageScrollsX
        case pageScrollsY
        case observedElementCount
        case truncation
        case isModalBoundary
        case containerName
        case frameX
        case frameY
        case frameWidth
        case frameHeight
        case children
    }

    func encode(to encoder: Encoder) throws {
        let fields = Self.fields(
            for: self.container,
            observedElementCount: observedElementCount,
            scrollInventory: scrollInventory
        )
        let frame = detail == .full ? ScreenFrameEvidence(container.frame).rect : nil

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fields.type, forKey: .type)
        try container.encodeIfPresent(fields.label, forKey: .label)
        try container.encodeIfPresent(fields.value, forKey: .value)
        try container.encodeIfPresent(fields.identifier, forKey: .identifier)
        try container.encodeIfPresent(fields.rowCount, forKey: .rowCount)
        try container.encodeIfPresent(fields.columnCount, forKey: .columnCount)
        try container.encodeIfPresent(Self.actionNames(self.container), forKey: .actions)
        try container.encodeIfPresent(fields.contentWidth, forKey: .contentWidth)
        try container.encodeIfPresent(fields.contentHeight, forKey: .contentHeight)
        try container.encodeIfPresent(fields.scrollAxis, forKey: .scrollAxis)
        try container.encodeIfPresent(fields.pageScrollsX, forKey: .pageScrollsX)
        try container.encodeIfPresent(fields.pageScrollsY, forKey: .pageScrollsY)
        try container.encodeIfPresent(fields.observedElementCount, forKey: .observedElementCount)
        try container.encodeIfPresent(truncation, forKey: .truncation)
        try container.encodeIfPresent(self.container.isModalBoundary ? true : nil, forKey: .isModalBoundary)
        try container.encodeIfPresent(containerName, forKey: .containerName)
        try container.encodeIfPresent(frame?.x.value, forKey: .frameX)
        try container.encodeIfPresent(frame?.y.value, forKey: .frameY)
        try container.encodeIfPresent(frame?.width.value, forKey: .frameWidth)
        try container.encodeIfPresent(frame?.height.value, forKey: .frameHeight)
        try container.encode(children, forKey: .children)
    }

    private static func actionNames(_ container: AccessibilityContainer) -> [String]? {
        let actions = container.customActions.map(\.name).filter { !$0.isEmpty }
        return actions.isEmpty ? nil : actions
    }

    private static func fields(
        for container: AccessibilityContainer,
        observedElementCount: Int,
        scrollInventory: ScrollInventory?
    ) -> Fields {
        let facts = container.containerPredicateFacts
        var fields: Fields
        switch facts.role {
        case .none:
            fields = Fields(type: .none, identifier: facts.identifier)
        case .semanticGroup(let label, let value):
            fields = Fields(type: .semanticGroup, label: label, value: value, identifier: facts.identifier)
        case .list:
            fields = Fields(type: .list, identifier: facts.identifier)
        case .landmark:
            fields = Fields(type: .landmark, identifier: facts.identifier)
        case .dataTable(let rowCount, let columnCount):
            fields = Fields(type: .dataTable, identifier: facts.identifier, rowCount: rowCount, columnCount: columnCount)
        case .tabBar:
            fields = Fields(type: .tabBar, identifier: facts.identifier)
        case .series:
            fields = Fields(type: .series, identifier: facts.identifier)
        }

        if let scrollableContentSize = container.scrollableContentSize {
            fields.addScrollFields(
                contentSize: scrollableContentSize,
                frame: container.frame,
                observedElementCount: observedElementCount,
                scrollInventory: scrollInventory
            )
        }
        return fields
    }

    private struct Fields {
        let type: AccessibilityContainerKind
        var label: String?
        var value: String?
        var identifier: String?
        var rowCount: Int?
        var columnCount: Int?
        var contentWidth: Double?
        var contentHeight: Double?
        var scrollAxis: String?
        var pageScrollsX: Int?
        var pageScrollsY: Int?
        var observedElementCount: Int?

        init(
            type: AccessibilityContainerKind,
            label: String? = nil,
            value: String? = nil,
            identifier: String? = nil,
            rowCount: Int? = nil,
            columnCount: Int? = nil,
            contentWidth: Double? = nil,
            contentHeight: Double? = nil,
            scrollAxis: String? = nil,
            pageScrollsX: Int? = nil,
            pageScrollsY: Int? = nil,
            observedElementCount: Int? = nil
        ) {
            self.type = type
            self.label = label
            self.value = value
            self.identifier = identifier
            self.rowCount = rowCount
            self.columnCount = columnCount
            self.contentWidth = contentWidth
            self.contentHeight = contentHeight
            self.scrollAxis = scrollAxis
            self.pageScrollsX = pageScrollsX
            self.pageScrollsY = pageScrollsY
            self.observedElementCount = observedElementCount
        }

        mutating func addScrollFields(
            contentSize: AccessibilitySize,
            frame: AccessibilityRect,
            observedElementCount: Int,
            scrollInventory: ScrollInventory?
        ) {
            guard let contentWidth = try? FiniteDimension(validating: contentSize.width),
                  let contentHeight = try? FiniteDimension(validating: contentSize.height),
                  let viewportWidth = try? FiniteDimension(validating: frame.size.width),
                  let viewportHeight = try? FiniteDimension(validating: frame.size.height)
            else { return }
            guard let metrics = ScrollContainerMetrics.project(
                contentWidth: contentWidth,
                contentHeight: contentHeight,
                viewportWidth: viewportWidth,
                viewportHeight: viewportHeight
            ) else { return }
            self.contentWidth = contentWidth.value
            self.contentHeight = contentHeight.value
            scrollAxis = metrics.axis.rawValue
            pageScrollsX = metrics.horizontalPageScrolls > 0 ? metrics.horizontalPageScrolls : nil
            pageScrollsY = metrics.verticalPageScrolls > 0 ? metrics.verticalPageScrolls : nil
            self.observedElementCount = scrollInventory?.totalElementCount
                ?? observedElementCount
        }
    }
}

extension InterfaceSubtreeTruncationProjection: Encodable {
    private enum CodingKeys: String, CodingKey {
        case state
        case reasonCode
        case observedElementCount
        case renderedElementCount
        case omittedElementCount
        case visibleElementBudget
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("truncated", forKey: .state)
        try container.encode("scroll-subtree-element-budget", forKey: .reasonCode)
        try container.encode(observedElementCount, forKey: .observedElementCount)
        try container.encode(renderedElementCount, forKey: .renderedElementCount)
        try container.encode(omittedElementCount, forKey: .omittedElementCount)
        try container.encode(visibleElementBudget, forKey: .visibleElementBudget)
    }
}
