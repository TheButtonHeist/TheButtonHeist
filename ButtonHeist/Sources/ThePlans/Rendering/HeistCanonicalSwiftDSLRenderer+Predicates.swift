import Foundation

extension HeistCanonicalSwiftDSLRenderer {
    func render(
        predicate: AccessibilityPredicate,
        environment: RenderEnvironment
    ) throws -> String {
        try render(predicateValue: predicate.core, environment: environment)
    }

    func render(
        predicate: PresenceCondition,
        environment: RenderEnvironment
    ) throws -> String {
        try render(presence: predicate, environment: environment)
    }

    private func render(
        predicateValue value: AccessibilityPredicate.Value,
        environment: RenderEnvironment
    ) throws -> String {
        switch value {
        case .presence(let presence):
            return try render(presence: presence, environment: environment)
        case .notification(let notification):
            return try render(notification: notification, environment: environment)
        case .screenChanged(let predicate):
            guard let match = predicate.match else { return ".screenChanged" }
            return try ".screenChanged(\(renderStringArgument(match, environment: environment)))"
        case .elementsChanged(let assertions):
            guard !assertions.isEmpty else { return ".elementsChanged" }
            let rendered = try assertions.map {
                try render(elementAssertion: $0, environment: environment)
            }
            return ".elementsChanged([\(rendered.joined(separator: ", "))])"
        }
    }

    private func render(
        notification: NotificationPredicate,
        environment: RenderEnvironment
    ) throws -> String {
        switch (notification.text, notification.element) {
        case (nil, nil):
            return ".notification"
        case (.some(let text), nil):
            return try ".notification(\(renderStringArgument(text, environment: environment)))"
        case (nil, .some(let element)):
            return try ".notification(element: \(render(predicate: element, environment: environment)))"
        case (.some(let text), .some(let element)):
            return try ".notification("
                + "text: \(renderStringArgument(text, environment: environment)), "
                + "element: \(render(predicate: element, environment: environment)))"
        }
    }

    private func render(
        presence: PresenceCondition,
        environment: RenderEnvironment
    ) throws -> String {
        switch presence {
        case .exists(let target):
            return try ".exists(\(render(target: target, environment: environment)))"
        case .missing(let target):
            return try ".missing(\(render(target: target, environment: environment)))"
        }
    }

    func render(
        elementAssertion assertion: ElementAssertion,
        environment: RenderEnvironment
    ) throws -> String {
        switch assertion {
        case .exists(let target):
            return try ".exists(\(render(target: target, environment: environment)))"
        case .missing(let target):
            return try ".missing(\(render(target: target, environment: environment)))"
        case .appeared(let target):
            return try ".appeared(\(render(target: target, environment: environment)))"
        case .disappeared(let target):
            return try ".disappeared(\(render(target: target, environment: environment)))"
        case .updated(let target, let change):
            return try ".updated(\(render(target: target, environment: environment)), "
                + "\(render(propertyChange: change, environment: environment)))"
        }
    }

    func render(
        propertyChange change: ElementPropertyChange,
        environment: RenderEnvironment
    ) throws -> String {
        switch change.value {
        case .value(let change):
            return try renderStringPropertyChange(
                "value",
                before: change.before,
                after: change.after,
                environment: environment
            )
        case .traits(let change):
            return renderTraitsPropertyChange(before: change.before, after: change.after)
        case .hint(let change):
            return try renderStringPropertyChange(
                "hint",
                before: change.before,
                after: change.after,
                environment: environment
            )
        case .actions(let change):
            return renderPropertyChange(
                "actions",
                before: change.before,
                after: change.after,
                render: render(actionSet:)
            )
        case .customContent(let change):
            return try renderPropertyChange(
                "customContent",
                before: change.before,
                after: change.after
            ) {
                try render(customContent: $0, environment: environment)
            }
        case .rotors(let change):
            return try renderPropertyChange(
                "rotors",
                before: change.before,
                after: change.after
            ) {
                try render(rotorSet: $0, environment: environment)
            }
        }
    }

    private func renderPropertyChange<Checker>(
        _ name: String,
        before: Checker?,
        after: Checker?,
        render: (Checker) throws -> String
    ) rethrows -> String {
        let fields = try [
            before.map { "before: \(try render($0))" },
            after.map { "after: \(try render($0))" },
        ].compactMap { $0 }
        return ".\(name)(\(fields.joined(separator: ", ")))"
    }

    private func renderStringPropertyChange(
        _ name: String,
        before: StringMatch?,
        after: StringMatch?,
        environment: RenderEnvironment
    ) throws -> String {
        if name == "value", before == nil, let after {
            return try ".value(\(renderStringArgument(after, environment: environment)))"
        }
        let fields = try [
            before.map { "before: \(try renderStringArgument($0, environment: environment))" },
            after.map { "after: \(try renderStringArgument($0, environment: environment))" },
        ].compactMap { $0 }
        return ".\(name)(\(fields.joined(separator: ", ")))"
    }

    private func renderTraitsPropertyChange(before: TraitSetMatch?, after: TraitSetMatch?) -> String {
        let fields = [
            before.map { "before: \(render(traitSet: $0))" },
            after.map { "after: \(render(traitSet: $0))" },
        ].compactMap { $0 }
        return ".traits(\(fields.joined(separator: ", ")))"
    }

    private func render(traitSet match: TraitSetMatch) -> String {
        let fields = renderIncludeExcludeFields(
            include: match.include.isEmpty ? nil : renderTraitArray(match.include),
            exclude: match.exclude.isEmpty ? nil : renderTraitArray(match.exclude)
        )
        return ".init(\(fields))"
    }

    private func render(actionSet match: ActionSetMatch) -> String {
        let fields = renderIncludeExcludeFields(
            include: match.include.isEmpty ? nil : renderActionArray(match.include),
            exclude: match.exclude.isEmpty ? nil : renderActionArray(match.exclude)
        )
        return ".init(\(fields))"
    }

    func render(
        customContent match: CustomContentMatch,
        environment: RenderEnvironment
    ) throws -> String {
        let fields = try renderCustomContentFields(
            label: match.label.map { try renderStringArgument($0, environment: environment) },
            value: match.value.map { try renderStringArgument($0, environment: environment) },
            isImportant: match.isImportant
        )
        return ".init(\(fields))"
    }

    private func render(
        rotorSet match: RotorSetMatch,
        environment: RenderEnvironment
    ) throws -> String {
        let include = match.include.isEmpty
            ? nil
            : try renderStringMatchArray(match.include, environment: environment)
        let exclude = match.exclude.isEmpty
            ? nil
            : try renderStringMatchArray(match.exclude, environment: environment)
        return ".init(\(renderIncludeExcludeFields(include: include, exclude: exclude)))"
    }

    private func renderIncludeExcludeFields(include: String?, exclude: String?) -> String {
        [
            include.map { "include: \($0)" },
            exclude.map { "exclude: \($0)" },
        ].compactMap { $0 }.joined(separator: ", ")
    }

    private func renderCustomContentFields(
        label: String?,
        value: String?,
        isImportant: Bool?
    ) -> String {
        [
            label.map { "label: \($0)" },
            value.map { "value: \($0)" },
            isImportant.map { "isImportant: \($0)" },
        ].compactMap { $0 }.joined(separator: ", ")
    }

    func renderActionArray(_ actions: Set<ElementAction>) -> String {
        let rendered = actions.sorted { $0.canonicalSortKey < $1.canonicalSortKey }
            .map(render(action:))
            .joined(separator: ", ")
        return "[\(rendered)]"
    }

    func render(action: ElementAction) -> String {
        switch action {
        case .activate:
            return ".activate"
        case .typeText:
            return ".typeText"
        case .increment:
            return ".increment"
        case .decrement:
            return ".decrement"
        case .custom(let name):
            return ".custom(\(quote(name.rawValue)))"
        }
    }

    func renderStringMatchArray(
        _ matches: [StringMatch],
        environment: RenderEnvironment
    ) throws -> String {
        let rendered = try matches.map {
            try renderStringArgument($0, environment: environment)
        }
        return "[\(rendered.joined(separator: ", "))]"
    }
}
