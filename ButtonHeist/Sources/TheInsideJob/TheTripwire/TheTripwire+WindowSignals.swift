#if canImport(UIKit)
#if DEBUG
import UIKit

extension TheTripwire {

    struct SemanticSignal: Sendable, Equatable {
        static let empty = SemanticSignal(windows: [])

        let windows: [SemanticWindowSignal]
    }

    /// Where UIKit has the user: the topmost controller, the navigation state
    /// and the window stack. Two readings taken under equal hierarchy signals
    /// describe the same place.
    struct HierarchySignal: Sendable, Equatable {
        let topmostVC: ObjectIdentifier?
        let navigation: NavigationSignal
        let windowStack: WindowStackSignal
    }

    struct SemanticWindowSignal: Sendable, Equatable {
        let level: Double
        let isKeyWindow: Bool
    }

    /// Cheap UIKit-side identity used to decide whether to re-check the
    /// accessibility tree. A changed Tripwire signal means "parse and check";
    /// it does not guarantee the parsed interface changed.
    struct TripwireSignal: Sendable, Equatable {
        static let empty = TripwireSignal(
            topmostVC: nil,
            navigation: .empty,
            windowStack: .empty,
            accessibilityNotificationSequence: 0
        )

        let topmostVC: ObjectIdentifier?
        let navigation: NavigationSignal
        let windowStack: WindowStackSignal
        let accessibilityNotificationSequence: UInt64

        init(
            topmostVC: ObjectIdentifier?,
            navigation: NavigationSignal,
            windowStack: WindowStackSignal,
            accessibilityNotificationSequence: UInt64 = 0
        ) {
            self.topmostVC = topmostVC
            self.navigation = navigation
            self.windowStack = windowStack
            self.accessibilityNotificationSequence = accessibilityNotificationSequence
        }

        /// The structural half of this signal: where UIKit has the user.
        ///
        /// Accessibility notifications are the other half and stay out of it.
        /// UIKit posts layout and value notifications throughout a transition,
        /// so they say a parse is worth doing, not that anything moved.
        var hierarchy: HierarchySignal {
            HierarchySignal(
                topmostVC: topmostVC,
                navigation: navigation,
                windowStack: windowStack
            )
        }

        var semanticValue: SemanticSignal {
            SemanticSignal(windows: windowStack.windows.map {
                SemanticWindowSignal(
                    level: Double($0.level),
                    isKeyWindow: $0.isKeyWindow
                )
            })
        }

        func recordingAccessibilityNotifications(through sequence: UInt64) -> Self {
            Self(
                topmostVC: topmostVC,
                navigation: navigation,
                windowStack: windowStack,
                accessibilityNotificationSequence: sequence
            )
        }
    }

    /// Public UIKit navigation state sampled from the topmost controller. This
    /// catches SwiftUI NavigationStack-style changes that remain inside one
    /// hosting controller, without walking SwiftUI's private view tree.
    struct NavigationSignal: Sendable, Equatable {
        static let empty = NavigationSignal(
            navigationDepth: nil,
            title: nil,
            backButtonTitle: nil,
            selectedTabIndex: nil,
            presentedViewController: nil
        )

        let navigationDepth: Int?
        let title: String?
        let backButtonTitle: String?
        let selectedTabIndex: Int?
        let presentedViewController: ObjectIdentifier?
    }

    /// Ordered visible window identity. Key-window status is deliberately part
    /// of the Tripwire signal, not an accessibility-scope filter.
    struct WindowStackSignal: Sendable, Equatable {
        static let empty = WindowStackSignal(windows: [])

        let windows: [WindowSignal]
    }

    struct WindowSignal: Sendable, Equatable {
        let id: ObjectIdentifier
        let level: CGFloat
        let isKeyWindow: Bool
    }

    struct WindowTraversalRoot {
        let window: UIWindow
        let rootView: UIView
    }

    // MARK: - Window Access

    /// All visible windows in foreground-active scenes, sorted by window level
    /// (front to back). Collects from all `UIWindowScene`s — not just key
    /// windows — so system-managed windows (popup menus, action sheets, alerts
    /// presented in their own UIWindow) are included without leaking inactive
    /// multi-window scenes into the accessibility tree.
    static func orderedVisibleWindows(includeFingerprints: Bool = false) -> [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap { $0.windows }
            .filter { window in
                (includeFingerprints || !(window is TheFingerprints.FingerprintWindow))
                    && !window.isHidden
                    && window.bounds.size != .zero
            }
            .sorted { $0.windowLevel > $1.windowLevel }
    }

    /// All visible windows in foreground-active scenes, sorted by window level
    /// (front to back).
    func captureTraversableWindows() -> [WindowTraversalRoot] {
        Self.orderedVisibleWindows()
            .map { WindowTraversalRoot(window: $0, rootView: $0) }
    }

    /// Tripwire identity sampled from public UIKit state without touching AX.
    func tripwireSignal() -> TripwireSignal {
        let windows = Self.orderedVisibleWindows()
        let entries = windows.map { WindowTraversalRoot(window: $0, rootView: $0) }
        let topmost = Self.topmostViewController(in: entries)
        return TripwireSignal(
            topmostVC: topmost.map(ObjectIdentifier.init),
            navigation: Self.navigationSignal(for: topmost),
            windowStack: Self.windowStackSignal(for: windows)
        )
    }

    /// Ordered visible window identity. Used as a change signal only; never
    /// as a rule for excluding lower windows from the accessibility tree.
    static func windowStackSignal(for windows: [UIWindow]) -> WindowStackSignal {
        WindowStackSignal(windows: windows.map { window in
            WindowSignal(
                id: ObjectIdentifier(window),
                level: window.windowLevel.rawValue,
                isKeyWindow: window.isKeyWindow
            )
        })
    }

    /// Public navigation signal for UIKit and SwiftUI-hosted screens.
    static func navigationSignal(for viewController: UIViewController?) -> NavigationSignal {
        guard let viewController else { return .empty }

        let navigationController = (viewController as? UINavigationController)
            ?? viewController.navigationController
        let tabBarController = (viewController as? UITabBarController)
            ?? viewController.tabBarController
        let navigationItem = viewController.navigationItem
        let topNavigationItem = navigationController?.navigationBar.topItem

        return NavigationSignal(
            navigationDepth: navigationController?.viewControllers.count,
            title: navigationItem.title ?? viewController.title ?? topNavigationItem?.title,
            backButtonTitle: navigationItem.backButtonTitle
                ?? navigationItem.backBarButtonItem?.title
                ?? topNavigationItem?.backButtonTitle
                ?? topNavigationItem?.backBarButtonItem?.title,
            selectedTabIndex: tabBarController?.selectedIndex,
            presentedViewController: viewController.presentedViewController.map(ObjectIdentifier.init)
        )
    }

    /// Windows that can be handed to the accessibility parser.
    ///
    /// This filter intentionally does not inspect the view hierarchy for
    /// `accessibilityViewIsModal`. It excludes system passthrough windows and
    /// preserves every remaining app window. The parser owns modal-scope
    /// discovery, and `TheVault` stops parsing lower windows when the parser
    /// emits a modal boundary container.
    ///
    /// Resolution steps, in order:
    /// 1. **System passthrough windows** — keyboard and text-effects windows
    ///    are excluded because they sit above `.normal` but contain no app
    ///    content the agent can usefully act on.
    /// 2. **Modal presentation** — each window whose root VC has a presented
    ///    VC is parsed from the deepest presented VC's view, matching what
    ///    `UIPresentationController` exposes to UIKit's AX for that window.
    ///
    /// For screenshots, use `captureTraversableWindows()` — visual compositing should
    /// include all windows so the dimmed background remains visible.
    func captureAccessibleWindows() -> [WindowTraversalRoot] {
        Self.filterToAccessibleWindows(captureTraversableWindows())
    }

    /// Whether a window is a system-managed decoration (keyboard, text-effects)
    /// that should not be treated as a modal takeover even though its window
    /// level is above `.normal`.
    nonisolated static func isSystemPassthroughWindow(_ window: UIWindow) -> Bool {
        systemPassthroughWindowClassNames.contains(NSStringFromClass(type(of: window)))
    }

    /// Pure filter applying the VoiceOver-equivalent precedence chain to a
    /// window list. Extracted from `captureAccessibleWindows()` so callers can
    /// supply a controlled list and the precedence logic can be exercised
    /// without depending on the host app's window state.
    ///
    /// `isPassthrough` lets tests inject a custom predicate so the
    /// passthrough branch can be exercised without instantiating private
    /// UIKit window classes.
    static func filterToAccessibleWindows(
        _ windows: [WindowTraversalRoot],
        isPassthrough: (UIWindow) -> Bool = isSystemPassthroughWindow
    ) -> [WindowTraversalRoot] {
        guard !windows.isEmpty else { return [] }

        let appWindows = windows.filter { !isPassthrough($0.window) }
        return appWindows.map { accessibleRootEntry($0) ?? $0 }
    }

    /// Return the view that should anchor accessibility parsing for a window.
    /// Parser-level UIKit guards handle private intermediary views; keeping the
    /// presented controller root preserves modal boundary metadata.
    private static func accessibleRootEntry(
        _ entry: WindowTraversalRoot
    ) -> WindowTraversalRoot? {
        guard let rootVC = entry.window.rootViewController else { return nil }
        let chain = Array(sequence(first: rootVC, next: \.presentedViewController))
        guard let deepest = chain.last else { return nil }
        guard let rootView = deepest.view else { return nil }
        guard rootView !== entry.rootView else {
            return deepest !== rootVC ? WindowTraversalRoot(window: entry.window, rootView: rootView) : nil
        }
        return WindowTraversalRoot(window: entry.window, rootView: rootView)
    }

    // MARK: - View Controller Identity

    /// The topmost visible view controller from public presentation and
    /// standard container state. Skips system passthrough windows (keyboard,
    /// text-effects) so a keyboard appearance doesn't falsely register as a
    /// view-controller change.
    func topmostViewController() -> UIViewController? {
        Self.topmostViewController(in: captureTraversableWindows())
    }

    /// Pure topmost-VC resolution against an explicit window list. Extracted
    /// so the passthrough-skip logic can be exercised in unit tests without
    /// relying on the host app's window state. `isPassthrough` lets tests
    /// inject a custom predicate without instantiating private UIKit window
    /// classes.
    static func topmostViewController(
        in windows: [WindowTraversalRoot],
        isPassthrough: (UIWindow) -> Bool = isSystemPassthroughWindow
    ) -> UIViewController? {
        guard let root = windows
            .first(where: { !isPassthrough($0.window) })?
            .window.rootViewController
        else {
            return nil
        }
        return deepestViewController(from: root)
    }

    private static func deepestViewController(from vc: UIViewController) -> UIViewController {
        if let presented = vc.presentedViewController {
            return deepestViewController(from: presented)
        }
        if let nav = vc as? UINavigationController, let top = nav.topViewController {
            return deepestViewController(from: top)
        }
        if let tab = vc as? UITabBarController, let selected = tab.selectedViewController {
            return deepestViewController(from: selected)
        }
        return vc
    }

}

#endif // DEBUG
#endif // canImport(UIKit)
