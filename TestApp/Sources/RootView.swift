import SwiftUI
import UIKit
@_spi(AdversarialLab) import ThePlans

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    private let startupRoute = AdversarialRoute.parseStartupEnvironment(
        ProcessInfo.processInfo.environment
    )
    @State private var adversarialRoute: AdversarialRoute?

    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Controls Demo") {
                    ControlsDemoView()
                }
                NavigationLink("Adversarial Lab") {
                    AdversarialLabView()
                }
                NavigationLink("Todo List") {
                    TodoListView()
                }
                NavigationLink("Notes") {
                    NotesView()
                }
                NavigationLink("Calculator") {
                    CalculatorView()
                }
                NavigationLink("Words") {
                    DictionaryView()
                }
                NavigationLink("Touch Canvas") {
                    TouchCanvasView()
                }
                NavigationLink("Playlist") {
                    PlaylistView()
                }
                NavigationLink("Messages") {
                    MessagesView()
                }
                NavigationLink("Contacts") {
                    ContactsView()
                }
                NavigationLink("Dashboard") {
                    DashboardView()
                }
                NavigationLink("Photos") {
                    PhotosView()
                }
                NavigationLink("Login") {
                    LoginView()
                }
                NavigationLink("Cart") {
                    CartView()
                }
                NavigationLink("Menu") {
                    MenuOrderView()
                }
                NavigationLink("Progress Button") {
                    ProgressButtonDemo()
                }
                NavigationLink("Long List") {
                    LongListView()
                }
                NavigationLink("Settings") {
                    SettingsView()
                }
                NavigationLink("Custom Content") {
                    CustomContentDemo()
                }
                NavigationLink("Custom Rotors") {
                    RotorsDemo()
                }
                NavigationLink("Tab Bar") {
                    TabBarDemoView()
                }

                Section("Auto-Settle Fixtures") {
                    NavigationLink("Transient Flow") {
                        TransientFlowDemo()
                    }
                    NavigationLink("Analog Clock") {
                        AnalogClockDemo()
                    }
                }

                Section("Modals") {
                    NavigationLink("Modal Window") {
                        ModalWindowDemo()
                    }
                    NavigationLink("Modal Permutations") {
                        ModalPermutationsDemo()
                    }
                    NavigationLink("Alerts & Sheets") {
                        AlertsSheetDemo()
                    }
                }

                Section("Scroll Tests") {
                    NavigationLink("Grid Gallery") {
                        GridGalleryView()
                    }
                    NavigationLink("Corner Scroll") {
                        CornerScrollView()
                    }
                    NavigationLink("Albums") {
                        AlbumFlowView()
                    }
                }

                Section("UIKit") {
                    NavigationLink("UIKit Form") {
                        UIKitFormDemoView()
                    }
                    NavigationLink("UIKit Table") {
                        UIKitTableDemoView()
                    }
                    NavigationLink("UIKit Collection") {
                        UIKitCollectionDemoView()
                    }
                }

                Section("Research") {
                    NavigationLink("SwiftUI Value Probe") {
                        SwiftUIAccessibilityValueProbeView()
                    }
                    NavigationLink("UIKit Value Probe") {
                        AccessibilityNotificationProbeView()
                    }
                    NavigationLink("Scroll SPI Harness") {
                        ScrollSPIHarnessView()
                    }
                    NavigationLink("Obscuring Harness") {
                        PresentationObscuringHarnessView()
                    }
                    NavigationLink("Trait Probe") {
                        TraitProbeView()
                    }
                    NavigationLink("Trait Validation") {
                        TraitValidationView()
                    }
                }
            }
            .navigationTitle("ButtonHeist Demo")
            .listRowInsets(settings.compactMode ? EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16) : nil)
        }
        .accessibilityHidden(adversarialRoute != nil)
        .overlay {
            if let route = adversarialRoute {
                NavigationStack {
                    AdversarialScenarioView(scenario: route.scenario)
                        .id(route.id)
                        .onAppear {
                            AdversarialLabRoute.observePresented(route.id)
                        }
                        .onDisappear {
                            AdversarialLabRoute.observeDismissed(route.id)
                        }
                }
                .background(Color(uiColor: .systemBackground))
            }
        }
        .onOpenURL(perform: openDemoRoute)
        .task {
            await Task.yield()
            AdversarialLabRoute.installPresenter { route in
                adversarialRoute = route
            }
            if let startupRoute {
                try? await AdversarialLabRoute.present(startupRoute)
            }
        }
        .onDisappear {
            AdversarialLabRoute.uninstallPresenter()
        }
    }

    private func openDemoRoute(_ url: URL) {
        guard url.scheme == "buttonheist-demo",
              url.host == "adversarial",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawScenario = components.queryItems?.first(where: { $0.name == "scenario" })?.value,
              let scenario = AdversarialScenarioCatalog.Route(rawValue: rawScenario),
              let rawRouteID = components.queryItems?.first(where: { $0.name == "route_id" })?.value,
              let routeID = UUID(uuidString: rawRouteID)
        else { return }
        Task {
            try? await AdversarialLabRoute.present(
                AdversarialRoute(id: routeID, scenario: scenario)
            )
        }
    }
}

struct AdversarialRoute: Identifiable, Hashable {
    static let startupEnvironmentKey = "BUTTONHEIST_ADVERSARIAL_ROUTE"

    let id: UUID
    let scenario: AdversarialScenarioCatalog.Route

    static func parseStartupEnvironment(
        _ environment: [String: String]
    ) -> AdversarialRoute? {
        guard let rawRoute = environment[startupEnvironmentKey],
              let route = AdversarialScenarioCatalog.Route(rawValue: rawRoute)
        else { return nil }
        return AdversarialRoute(id: UUID(), scenario: route)
    }
}

@MainActor
internal final class AdversarialLabRoute {
    typealias Presenter = (AdversarialRoute?) -> Void

    private enum Phase {
        case unavailable
        case idle(Presenter)
        case presenting(Presenter, routeID: UUID)
        case presented(Presenter, routeID: UUID)
        case dismissing(Presenter, routeID: UUID)
    }

    private static var phase = Phase.unavailable

    private init() {}

    internal static func open(_ scenario: AdversarialScenarioCatalog.Route) async throws {
        try await present(AdversarialRoute(id: UUID(), scenario: scenario))
    }

    static func present(_ route: AdversarialRoute) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        let presenter = try await idlePresenter(clock: clock, deadline: deadline)
        phase = .presenting(presenter, routeID: route.id)
        presenter(route)

        while true {
            if case .presented(_, let presentedRouteID) = phase,
               presentedRouteID == route.id {
                return
            }
            guard clock.now < deadline else { throw AdversarialLabRouteError.timedOut(route.scenario) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func installPresenter(
        _ presenter: @escaping Presenter
    ) {
        phase = .idle(presenter)
    }

    static func uninstallPresenter() {
        phase = .unavailable
    }

    static func observePresented(_ routeID: UUID) {
        guard case .presenting(let presenter, let presentingRouteID) = phase,
              presentingRouteID == routeID else { return }
        phase = .presented(presenter, routeID: routeID)
    }

    static func observeDismissed(_ routeID: UUID) {
        switch phase {
        case .presented(let presenter, let presentedRouteID)
            where presentedRouteID == routeID:
            phase = .idle(presenter)
        case .presenting(let presenter, let presentingRouteID)
            where presentingRouteID == routeID:
            phase = .idle(presenter)
        case .dismissing(let presenter, let dismissingRouteID)
            where dismissingRouteID == routeID:
            phase = .idle(presenter)
        case .unavailable, .idle, .presenting, .presented, .dismissing:
            break
        }
    }

    private static func idlePresenter(
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws -> Presenter {
        while true {
            switch phase {
            case .idle(let presenter):
                return presenter
            case .presented(let presenter, let routeID):
                phase = .dismissing(presenter, routeID: routeID)
                presenter(nil)
            case .unavailable, .presenting, .dismissing:
                break
            }
            guard clock.now < deadline else { throw AdversarialLabRouteError.hostTimedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

internal enum AdversarialLabRouteError: Error {
    case hostTimedOut
    case timedOut(AdversarialScenarioCatalog.Route)
}
