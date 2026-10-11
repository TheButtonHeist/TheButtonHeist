#if canImport(UIKit)
#if DEBUG
import SwiftUI
import UIKit

private enum FingerprintAppearance {
    static let symbolName = "touchid"
    static let ultraviolet = UIColor(red: 0.86, green: 0.26, blue: 1.0, alpha: 1.0)
    static let violet = UIColor(red: 0.52, green: 0.06, blue: 1.0, alpha: 1.0)
    static let residue = UIColor(red: 0.96, green: 0.9, blue: 1.0, alpha: 1.0)
    static let displayDiameter: CGFloat = 76
}

private struct FingerprintState: Identifiable, Equatable {
    let id: Int
    var center: CGPoint
    var isVisible: Bool
}

@MainActor
private final class FingerprintOverlayModel: ObservableObject {
    @Published var fingerprints: [FingerprintState] = []

    func centers(for ids: [Int]) -> [CGPoint] {
        ids.compactMap { id in
            fingerprints.first(where: { $0.id == id })?.center
        }
    }

    func append(_ newFingerprints: [FingerprintState]) {
        fingerprints.append(contentsOf: newFingerprints)
    }

    func remove(ids: [Int]) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        fingerprints.removeAll { idSet.contains($0.id) }
    }

    func removeAll() {
        fingerprints = []
    }

    func setVisibility(for ids: [Int], isVisible: Bool) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        var updatedFingerprints = fingerprints
        for index in updatedFingerprints.indices where idSet.contains(updatedFingerprints[index].id) {
            updatedFingerprints[index].isVisible = isVisible
        }
        fingerprints = updatedFingerprints
    }

    func updateCenters(for ids: [Int], to points: [CGPoint]) {
        guard !ids.isEmpty else { return }
        var updatedFingerprints = fingerprints
        for (id, point) in zip(ids, points) {
            guard let index = updatedFingerprints.firstIndex(where: { $0.id == id }) else {
                continue
            }
            updatedFingerprints[index].center = point
        }
        fingerprints = updatedFingerprints
    }
}

private struct FingerprintOverlayView: View {
    @ObservedObject var model: FingerprintOverlayModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.fingerprints) { fingerprint in
                FingerprintGlyph()
                    .frame(
                        width: FingerprintAppearance.displayDiameter,
                        height: FingerprintAppearance.displayDiameter
                    )
                    .position(x: fingerprint.center.x, y: fingerprint.center.y)
                    .opacity(fingerprint.isVisible ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct FingerprintGlyph: View {
    private let diameter = FingerprintAppearance.displayDiameter

    var body: some View {
        ZStack {
            Image(systemName: FingerprintAppearance.symbolName)
                .resizable()
                .scaledToFit()
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color(uiColor: FingerprintAppearance.violet.withAlphaComponent(0.74)))
                .frame(width: diameter * 0.72, height: diameter * 0.72)
                .blur(radius: 4)

            Image(systemName: FingerprintAppearance.symbolName)
                .resizable()
                .scaledToFit()
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color(uiColor: FingerprintAppearance.ultraviolet.withAlphaComponent(0.78)))
                .frame(width: diameter * 0.62, height: diameter * 0.62)
                .shadow(
                    color: Color(uiColor: FingerprintAppearance.violet.withAlphaComponent(0.95)),
                    radius: 11
                )

            Image(systemName: FingerprintAppearance.symbolName)
                .resizable()
                .scaledToFit()
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color(uiColor: FingerprintAppearance.residue.withAlphaComponent(1)))
                .frame(width: diameter * 0.54, height: diameter * 0.54)
                .shadow(
                    color: Color(uiColor: FingerprintAppearance.ultraviolet.withAlphaComponent(1)),
                    radius: 5
                )
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// Visual interaction indicators for ButtonHeist-delivered interactions.
@MainActor
final class TheFingerprints {

    /// Passthrough window for fingerprint indicators. TheTripwire filters this
    /// window from traversal so the overlay does not affect settle or hit tests.
    final class FingerprintWindow: UIWindow {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }

    private static let appearDuration: TimeInterval = 0.08
    private static let minimumDisplayDuration: TimeInterval = 0.5
    private static let fadeOutDuration: TimeInterval = 0.22

    private final class OverlayContext {
        var window: FingerprintWindow
        var retirements: [Int: [Int]] = [:]

        init(window: FingerprintWindow) {
            self.window = window
        }
    }

    private struct TrackingSession {
        let context: OverlayContext
        var fingerprintIDs: [Int]
        let startedAt: CFTimeInterval
    }

    private enum Lifecycle {
        case detached
        case idle(OverlayContext)
        case tracking(TrackingSession)
    }

    enum LifecycleSnapshot: Equatable {
        case detached
        case idle(pendingRetirementCount: Int)
        case tracking(activeFingerprintCount: Int, pendingRetirementCount: Int)
    }

    private var lifecycle: Lifecycle = .detached
    private let overlayModel = FingerprintOverlayModel()
    private var nextFingerprintID = 0
    private var nextRetirementID = 0

    private let isEnabled: Bool
    private let now: () -> CFTimeInterval
    private let schedule: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    var fingerprintWindow: FingerprintWindow? { currentContext?.window }

    var activeFingerprintCenters: [CGPoint] {
        guard case let .tracking(session) = lifecycle else { return [] }
        return overlayModel.centers(for: session.fingerprintIDs)
    }

    var lifecycleSnapshot: LifecycleSnapshot {
        switch lifecycle {
        case .detached:
            .detached
        case let .idle(context):
            .idle(pendingRetirementCount: context.retirements.count)
        case let .tracking(session):
            .tracking(
                activeFingerprintCount: session.fingerprintIDs.count,
                pendingRetirementCount: session.context.retirements.count
            )
        }
    }

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
        now = { CACurrentMediaTime() }
        schedule = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                action()
            }
        }
    }

    init(
        isEnabled: Bool,
        now: @escaping () -> CFTimeInterval,
        schedule: @escaping (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    ) {
        self.isEnabled = isEnabled
        self.now = now
        self.schedule = schedule
    }

    func beginTracking(at points: [CGPoint]) {
        guard isEnabled, !points.isEmpty else { return }
        guard let context = attachFingerprintOverlayIfNeeded() else { return }

        removeActiveFingerprints()
        let fingerprints = points.map(makeFingerprint(at:))
        let fingerprintIDs = fingerprints.map(\.id)

        lifecycle = .tracking(TrackingSession(
            context: context,
            fingerprintIDs: fingerprintIDs,
            startedAt: now()
        ))

        overlayModel.append(fingerprints)
        fadeInFingerprints(ids: fingerprintIDs)
    }

    func show(at point: CGPoint) {
        beginTracking(at: [point])
        endTracking()
    }

    func show(at points: [CGPoint]) {
        beginTracking(at: points)
        endTracking()
    }

    func updateTracking(to points: [CGPoint]) {
        guard isEnabled else { return }
        guard !points.isEmpty else {
            removeActiveFingerprints()
            return
        }
        guard attachFingerprintOverlayIfNeeded() != nil else { return }

        guard case var .tracking(session) = lifecycle else {
            beginTracking(at: points)
            return
        }

        if points.count < session.fingerprintIDs.count {
            let removedIDs = Array(session.fingerprintIDs.suffix(session.fingerprintIDs.count - points.count))
            session.fingerprintIDs.removeLast(session.fingerprintIDs.count - points.count)
            overlayModel.remove(ids: removedIDs)
        }

        if points.count > session.fingerprintIDs.count {
            let fingerprints = points[session.fingerprintIDs.count...].map(makeFingerprint(at:))
            let newIDs = fingerprints.map(\.id)
            session.fingerprintIDs.append(contentsOf: newIDs)
            overlayModel.append(fingerprints)
            fadeInFingerprints(ids: newIDs)
        }

        lifecycle = .tracking(session)
        overlayModel.updateCenters(for: session.fingerprintIDs, to: points)
    }

    func endTracking() {
        guard case let .tracking(session) = lifecycle else { return }
        let ids = session.fingerprintIDs
        let elapsed = now() - session.startedAt
        let remainingHold = max(Self.minimumDisplayDuration - elapsed, 0)

        nextRetirementID += 1
        let retirementID = nextRetirementID
        session.context.retirements[retirementID] = ids
        lifecycle = .idle(session.context)

        schedule(remainingHold) { [weak self] in
            self?.beginFadeOut(retirementID: retirementID)
        }
    }

    func invalidate() {
        currentContext?.window.isHidden = true
        currentContext?.window.rootViewController = nil
        overlayModel.removeAll()
        lifecycle = .detached
    }

    private func makeFingerprint(at point: CGPoint) -> FingerprintState {
        nextFingerprintID += 1
        return FingerprintState(id: nextFingerprintID, center: point, isVisible: false)
    }

    private func fadeInFingerprints(ids: [Int]) {
        schedule(0) { [overlayModel] in
            withAnimation(.easeOut(duration: Self.appearDuration)) {
                overlayModel.setVisibility(for: ids, isVisible: true)
            }
        }
    }

    private func removeActiveFingerprints() {
        guard case let .tracking(session) = lifecycle else { return }
        overlayModel.remove(ids: session.fingerprintIDs)
        lifecycle = .idle(session.context)
    }

    private func beginFadeOut(retirementID: Int) {
        guard let ids = currentContext?.retirements[retirementID] else { return }

        withAnimation(.easeOut(duration: Self.fadeOutDuration)) {
            overlayModel.setVisibility(for: ids, isVisible: false)
        }

        schedule(Self.fadeOutDuration) { [weak self] in
            self?.completeRetirement(id: retirementID)
        }
    }

    private func completeRetirement(id: Int) {
        guard let context = currentContext,
              let ids = context.retirements.removeValue(forKey: id)
        else { return }

        overlayModel.remove(ids: ids)
    }

    private func attachFingerprintOverlayIfNeeded() -> OverlayContext? {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else {
            return nil
        }

        if currentContext?.window.windowScene !== windowScene {
            let window = FingerprintWindow(windowScene: windowScene)
            window.frame = windowScene.screen.bounds
            window.backgroundColor = .clear
            window.windowLevel = .statusBar + 100
            window.isUserInteractionEnabled = false
            window.isAccessibilityElement = false
            window.accessibilityElementsHidden = true

            let viewController = UIHostingController(rootView: FingerprintOverlayView(model: overlayModel))
            viewController.view.frame = window.bounds
            viewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            viewController.view.backgroundColor = .clear
            viewController.view.isOpaque = false
            viewController.view.isUserInteractionEnabled = false
            viewController.view.isAccessibilityElement = false
            viewController.view.accessibilityElementsHidden = true

            window.rootViewController = viewController
            window.isHidden = false
            replaceWindow(window)
        }

        return currentContext
    }

    private var currentContext: OverlayContext? {
        switch lifecycle {
        case .detached:
            nil
        case let .idle(context):
            context
        case let .tracking(session):
            session.context
        }
    }

    private func replaceWindow(_ window: FingerprintWindow) {
        if let context = currentContext {
            context.window.isHidden = true
            context.window.rootViewController = nil
            context.window = window
            return
        }

        lifecycle = .idle(OverlayContext(window: window))
    }
}

#Preview("TheFingerprints UV") {
    FingerprintPreviewCanvas()
}

private struct FingerprintPreviewCanvas: View {
    private let rows = [
        ["AC", "+/-", "%", "/"],
        ["7", "8", "9", "x"],
        ["4", "5", "6", "-"],
        ["1", "2", "3", "+"],
        ["0", ".", "="],
    ]

    var body: some View {
        VStack(spacing: 12) {
            Text("12")
                .font(.system(size: 64, weight: .light, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 120)
                .padding(.horizontal, 24)

            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 12) {
                    ForEach(Array(row.enumerated()), id: \.offset) { columnIndex, label in
                        FingerprintPreviewKey(
                            label: label,
                            width: label == "0" ? 156 : 72,
                            kind: keyKind(label),
                            showsFingerprint: shouldShowFingerprint(row: rowIndex, column: columnIndex)
                        )
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 390, height: 844)
        .background(Color(uiColor: .systemBackground))
    }

    private func keyKind(_ label: String) -> FingerprintPreviewKey.Kind {
        if ["/", "x", "-", "+", "="].contains(label) { return .operation }
        if ["AC", "+/-", "%"].contains(label) { return .utility }
        return .number
    }

    private func shouldShowFingerprint(row: Int, column: Int) -> Bool {
        (row == 0 && column == 0) || (row == 3 && column < 2)
    }
}

private struct FingerprintPreviewKey: View {
    enum Kind {
        case utility
        case number
        case operation
    }

    let label: String
    let width: CGFloat
    let kind: Kind
    let showsFingerprint: Bool

    var body: some View {
        Text(label)
            .font(.title2.weight(.medium))
            .frame(width: width, height: 72)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                if showsFingerprint {
                    FingerprintGlyph()
                }
            }
    }

    private var backgroundColor: Color {
        switch kind {
        case .operation:
            return .orange
        case .utility:
            return Color(uiColor: .systemGray4)
        case .number:
            return Color(uiColor: .systemGray5)
        }
    }

    private var foregroundColor: Color {
        switch kind {
        case .operation:
            return .white
        case .utility, .number:
            return .primary
        }
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
