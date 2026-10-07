import Foundation

import TheScore

extension InterfaceRenderingProjection: Encodable {
    private enum CodingKeys: String, CodingKey {
        case completeness
        case reasonCode
        case observedElementCount
        case renderedElementCount
        case omittedElementCount
        case visibleElementBudget
        case totalNodeBudget
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(completeness.rawValue, forKey: .completeness)
        try container.encodeIfPresent(reason?.rawValue, forKey: .reasonCode)
        try container.encode(observedElementCount, forKey: .observedElementCount)
        try container.encode(renderedElementCount, forKey: .renderedElementCount)
        try container.encode(omittedElementCount, forKey: .omittedElementCount)
        try container.encodeIfPresent(visibleElementBudget, forKey: .visibleElementBudget)
        try container.encodeIfPresent(totalNodeBudget, forKey: .totalNodeBudget)
    }
}

extension InterfaceNodeProjection: Encodable {
    private enum CodingKeys: String, CodingKey {
        case element
        case container
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .element(let element):
            try container.encode(
                PublicElement(
                    element: element.element,
                    detail: projectedDetail,
                    order: element.order,
                    target: element.target
                ),
                forKey: .element
            )
        case .container(let node):
            try container.encode(node, forKey: .container)
        }
    }

    private var projectedDetail: InterfaceDetail {
        switch self {
        case .element(let element):
            return element.detail
        case .container(let container):
            return container.detail
        }
    }
}
