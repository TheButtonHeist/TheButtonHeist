import Foundation

package struct HeistActionCommandTargetOccurrence: Sendable, Equatable {
    package enum Role: Sendable, Equatable {
        case semantic
        case gesture
        case scroll
    }

    package enum Path: Sendable, Equatable {
        case payloadTarget
        case payloadElement
        case payloadStartElement

        package func appending(to commandPath: HeistPlanPath) -> HeistPlanPath {
            switch self {
            case .payloadTarget:
                return commandPath.child(.payload).child(.target)
            case .payloadElement:
                return commandPath.child(.payload).child(.element)
            case .payloadStartElement:
                return commandPath.child(.payload).child(.start).child(.element)
            }
        }
    }

    package let role: Role
    package let path: Path
    package let target: AccessibilityTarget

    package init(role: Role, path: Path, target: AccessibilityTarget) {
        self.role = role
        self.path = path
        self.target = target
    }

    package var reportTarget: AccessibilityTarget? {
        guard (try? target.resolve(in: .empty)) != nil else { return nil }
        return target
    }
}

extension HeistActionCommand {
    package var targetOccurrences: [HeistActionCommandTargetOccurrence] {
        switch self {
        case .activate(let target), .increment(let target), .decrement(let target):
            return [.semantic(target)]
        case .customAction(_, let target), .rotor(_, let target, _):
            return [.semantic(target)]
        case .typeText(let payload):
            return payload.target.map { [.semantic($0)] } ?? []
        case .oneFingerTap(let target):
            return target.selection.targetOccurrences(role: .gesture, path: .payloadElement)
        case .longPress(let target):
            return target.selection.targetOccurrences(role: .gesture, path: .payloadElement)
        case .swipe(let target):
            return target.selection.targetOccurrences
        case .drag(let target):
            return target.selection.targetOccurrences
        case .scroll(let target):
            return target.selection.targetOccurrences
        case .scrollToVisible(let target):
            return [.scroll(target)]
        case .scrollToEdge(let target):
            return target.selection.targetOccurrences
        case .dismiss, .magicTap, .editAction, .setPasteboard, .takeScreenshot, .dismissKeyboard:
            return []
        }
    }
}

public extension HeistActionCommand {
    var durableHeistActionFailure: String? {
        switch self {
        case .rotor(let selection, _, _):
            if case .named = selection { return nil }
            return "rotor selection \(selection) is not a durable heist action"
        case .scroll:
            return "scroll is a direct client command, not a durable heist action"
        case .scrollToVisible:
            return "scroll_to_visible is a direct client command, not a durable heist action"
        case .scrollToEdge:
            return "scroll_to_edge is a direct client command, not a durable heist action"
        case .activate, .increment, .decrement, .customAction, .typeText, .oneFingerTap, .longPress,
             .swipe, .drag, .dismiss, .magicTap, .editAction, .setPasteboard, .takeScreenshot,
             .dismissKeyboard:
            return nil
        }
    }

    var reportTarget: AccessibilityTarget? {
        targetOccurrences.lazy.compactMap { $0.reportTarget }.first
    }
}

private extension HeistActionCommandTargetOccurrence {
    static func semantic(_ target: AccessibilityTarget) -> Self {
        Self(role: .semantic, path: .payloadTarget, target: target)
    }

    static func scroll(_ target: AccessibilityTarget) -> Self {
        Self(role: .scroll, path: .payloadTarget, target: target)
    }

    static func element(_ target: AccessibilityTarget, role: Role, path: Path) -> Self {
        Self(role: role, path: path, target: target)
    }
}

private extension GesturePointSelection {
    func targetOccurrences(
        role: HeistActionCommandTargetOccurrence.Role,
        path: HeistActionCommandTargetOccurrence.Path
    ) -> [HeistActionCommandTargetOccurrence] {
        switch self {
        case .element(let target), .elementUnitPoint(let target, _):
            return [.element(target, role: role, path: path)]
        case .coordinate:
            return []
        }
    }
}

private extension SwipeGestureSelection {
    var targetOccurrences: [HeistActionCommandTargetOccurrence] {
        switch self {
        case .unitElement(let target, _, _), .elementDirection(let target, _):
            return [.element(target, role: .gesture, path: .payloadElement)]
        case .pointToPoint, .pointDirection:
            return []
        }
    }
}

private extension DragGestureSelection {
    var targetOccurrences: [HeistActionCommandTargetOccurrence] {
        switch self {
        case .elementToPoint(let target, _, _):
            return [.element(target, role: .gesture, path: .payloadElement)]
        case .pointToPoint:
            return []
        }
    }
}

private extension ScrollContainerSelection {
    var targetOccurrences: [HeistActionCommandTargetOccurrence] {
        switch self {
        case .element(let target):
            return [.element(target, role: .scroll, path: .payloadTarget)]
        case .visibleContainer, .container:
            return []
        }
    }
}
