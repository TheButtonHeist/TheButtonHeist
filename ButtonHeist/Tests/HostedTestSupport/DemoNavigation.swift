#if canImport(UIKit)
import UIKit
import ButtonHeistTesting

package enum DemoNavigation {
    private static let anyBackTarget = ElementPredicate(traits: [.backButton])
    private static let rootBackTarget = ElementPredicate(label: .exact("ButtonHeist Demo"), traits: [.button])
    private static let rootTitle = ElementPredicate(label: .exact("ButtonHeist Demo"), traits: [.header])
    private static let longListFirstRow = ElementPredicate(label: .exact("Widget 0, Hardware"))
    private static let backChromeSettleTimeout = 0.25

    package static let backToRootIfNeeded = HeistDef<Void>("DemoNavigation.backToRootIfNeeded") {
        try backOneLevelIfNeeded()
        try backOneLevelIfNeeded()
        try backOneLevelIfNeeded()
        try backOneLevelIfNeeded()
        try backOneLevelIfNeeded()
        WaitFor(.missing(.predicate(anyBackTarget)), timeout: 2)
        WaitFor(.missing(.predicate(rootBackTarget)), timeout: 2)
        WaitFor(.exists(.predicate(rootTitle)), timeout: 4)
    }

    package static let backToRoot = HeistDef<Void>("DemoNavigation.backToRoot") {
        try backToRootIfNeeded()
    }

    package static let openMenu = HeistDef<Void>("DemoNavigation.openMenu") {
        try backToRootIfNeeded()

        WaitFor(.exists(.label("Menu")), timeout: 4)
        Activate(.label("Menu"))
            .expect(.screenChanged, timeout: 8)
        WaitFor(.exists(.label("Menu")), timeout: 8)
    }

    package static let backTo = HeistDef<String>("DemoNavigation.backTo", parameter: "title") { title in
        let destinationTitle = ElementPredicate(label: .exact(title), traits: [.header])

        Activate(.predicate(ElementPredicate(label: .exact(title), traits: [.backButton])))
            .expect(.exists(.predicate(destinationTitle)), timeout: 8)
    }

    private static let backOneLevelIfNeeded = HeistDef<Void>("DemoNavigation.backOneLevelIfNeeded") {
        let reanchor = try reanchorLongListIfNeeded()
        let chromeWait = WaitFor(
            .exists(.predicate(rootBackTarget)),
            timeout: try .seconds(backChromeSettleTimeout)
        ).else {}

        // Outgoing Back chrome can remain observable after the root title appears.
        If {
            Case(.missing(.predicate(rootTitle))) {
                reanchor
                chromeWait

                If {
                    Case(.exists(.predicate(rootBackTarget))) {
                        Activate(.predicate(rootBackTarget))
                            .expect(.screenChanged, timeout: 8)
                    }
                    Case(.exists(.predicate(anyBackTarget))) {
                        Activate(.predicate(anyBackTarget))
                            .expect(.screenChanged, timeout: 8)
                    }
                    Else {}
                }
            }
        }
    }

    private static let reanchorLongListIfNeeded = HeistDef<Void>("DemoNavigation.reanchorLongListIfNeeded") {
        If {
            Case(.exists(.predicate(longListFirstRow))) {
                WaitFor(.exists(.predicate(longListFirstRow)), timeout: 1)
            }
            Else {}
        }
    }
}

#endif // canImport(UIKit)
