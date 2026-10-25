import SwiftUI
import UIKit

internal struct NestedScrollScenarioView: UIViewControllerRepresentable {
    // MARK: - UIViewControllerRepresentable

    func makeUIViewController(context: Context) -> UIViewController {
        NestedScrollViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

/// Value evidence emitted by the live nested-scroll fixture so app-hosted tests
/// can cancel at a real movement boundary instead of guessing discovery timing.
internal struct NestedScrollScenarioEvidence: Equatable, Sendable {
    internal let outerOffset: String
    internal let innerOffset: String
    internal let outerMovementCount: Int
    internal let innerMovementCount: Int
    internal let outerRestorationCount: Int
    internal let innerRestorationCount: Int
    internal let activationCount: Int
}

/// This is deliberately a test observation boundary, not a navigation API.
/// The fixture remains driven through the same accessibility surface as every
/// other adversarial route; tests only use this stream to choose cancellation
/// at an observed real-world boundary.
@MainActor
internal enum NestedScrollScenarioInstrumentation {
    private static var continuation: AsyncStream<NestedScrollScenarioEvidence>.Continuation?

    internal static func prepare() -> AsyncStream<NestedScrollScenarioEvidence> {
        continuation?.finish()
        let stream = AsyncStream<NestedScrollScenarioEvidence>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        continuation = stream.continuation
        return stream.stream
    }

    internal static func record(_ evidence: NestedScrollScenarioEvidence) {
        continuation?.yield(evidence)
    }

    internal static func finish() {
        continuation?.finish()
        continuation = nil
    }
}

/// UIScrollView that publishes real offset attempts and movements as accessibility evidence.
internal final class AdversarialScrollEvidenceView: UIScrollView {
    // MARK: - Properties

    internal weak var attemptEvidenceLabel: UILabel?
    internal weak var movementEvidenceLabel: UILabel?
    internal weak var visibilityEvidenceLabel: UILabel?
    internal weak var observedTarget: UIView?
    internal var onEvidenceChange: (@MainActor (AdversarialScrollEvidenceView) -> Void)?
    internal private(set) var offsetAttemptCount = 0
    internal private(set) var offsetMovementCount = 0
    internal private(set) var originRestorationCount = 0
    private var isTrackingEvidence = false
    private var originContentOffset = CGPoint.zero
    private var movedAwayFromOrigin = false

    override var contentOffset: CGPoint {
        didSet {
            recordOffset(contentOffset)
            publishEvidence()
        }
    }

    // MARK: - Offset Evidence

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        let previousOffset = self.contentOffset
        if isTrackingEvidence {
            offsetAttemptCount += 1
        }
        super.setContentOffset(contentOffset, animated: animated)
        if isTrackingEvidence, self.contentOffset != previousOffset {
            offsetMovementCount += 1
        }
        publishEvidence()
    }

    internal func beginEvidenceTracking() {
        guard !isTrackingEvidence else { return }
        resetEvidence()
        originContentOffset = contentOffset
        isTrackingEvidence = true
    }

    internal func resetEvidence() {
        offsetAttemptCount = 0
        offsetMovementCount = 0
        originRestorationCount = 0
        originContentOffset = contentOffset
        movedAwayFromOrigin = false
        publishEvidence()
    }

    internal func publishEvidence() {
        attemptEvidenceLabel?.accessibilityValue = String(offsetAttemptCount)
        movementEvidenceLabel?.accessibilityValue = String(offsetMovementCount)
        if let visibilityEvidenceLabel, let observedTarget {
            visibilityEvidenceLabel.accessibilityValue = bounds.intersects(observedTarget.frame)
                ? "Visible"
                : "Offscreen"
        }
        onEvidenceChange?(self)
    }

    internal var offsetEvidence: String {
        String(format: "%.2f, %.2f", contentOffset.x, contentOffset.y)
    }

    private func recordOffset(_ offset: CGPoint) {
        guard isTrackingEvidence else { return }
        if offset != originContentOffset {
            movedAwayFromOrigin = true
        } else if movedAwayFromOrigin {
            originRestorationCount += 1
            movedAwayFromOrigin = false
        }
    }
}

private final class NestedScrollViewController: UIViewController {
    // MARK: - Properties

    private let evidenceStack = UIStackView()
    private let outerScrollView = AdversarialScrollEvidenceView()
    private let innerScrollView = AdversarialScrollEvidenceView()
    private let outerAttemptLabel = UILabel()
    private let outerMovementLabel = UILabel()
    private let innerAttemptLabel = UILabel()
    private let innerMovementLabel = UILabel()
    private let outerRestorationLabel = UILabel()
    private let innerRestorationLabel = UILabel()
    private let outerOffsetLabel = UILabel()
    private let innerOffsetLabel = UILabel()
    private let restorationStateLabel = UILabel()
    private let replacementModeLabel = UILabel()
    private let activationCountLabel = UILabel()
    private let selectedLabel = UILabel()
    private let deepCutsLabel = UILabel()
    private let targetButton = UIButton(type: .system)
    private let replacementArmButton = UIButton(type: .system)
    private var targetRevealOffset: CGFloat = 1
    private var activationCount = 0
    private var replacementArmed = false
    private var emittedBothMoved = false
    private var emittedRestoration = false
    private var didReplaceScreen = false

    // MARK: - View Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Nested Scroll"
        view.backgroundColor = .systemGroupedBackground

        configureEvidenceLabel(outerAttemptLabel, title: "Nested outer scroll attempts")
        configureEvidenceLabel(outerMovementLabel, title: "Nested outer scroll movements")
        configureEvidenceLabel(innerAttemptLabel, title: "Nested inner scroll attempts")
        configureEvidenceLabel(innerMovementLabel, title: "Nested inner scroll movements")
        configureEvidenceLabel(outerRestorationLabel, title: "Nested outer restorations")
        configureEvidenceLabel(innerRestorationLabel, title: "Nested inner restorations")
        configureEvidenceLabel(outerOffsetLabel, title: "Nested outer offset")
        configureEvidenceLabel(innerOffsetLabel, title: "Nested inner offset")
        configureEvidenceLabel(restorationStateLabel, title: "Nested restoration state")
        configureEvidenceLabel(replacementModeLabel, title: "Nested replacement mode")
        configureEvidenceLabel(activationCountLabel, title: "Nested target activations")
        restorationStateLabel.accessibilityValue = "Pending"
        replacementModeLabel.accessibilityValue = "Inactive"
        selectedLabel.text = "No nested selection"

        replacementArmButton.setTitle("Replace nested screen after scroll", for: .normal)
        replacementArmButton.addTarget(
            self,
            action: #selector(armScreenReplacement),
            for: .touchUpInside
        )

        evidenceStack.axis = .vertical
        evidenceStack.spacing = 4
        evidenceStack.translatesAutoresizingMaskIntoConstraints = false
        let heading = UILabel()
        heading.text = "Nested Scroll"
        heading.accessibilityTraits.insert(.header)
        [
            heading,
            outerAttemptLabel,
            outerMovementLabel,
            innerAttemptLabel,
            innerMovementLabel,
            outerRestorationLabel,
            innerRestorationLabel,
            outerOffsetLabel,
            innerOffsetLabel,
            restorationStateLabel,
            replacementModeLabel,
            activationCountLabel,
            selectedLabel,
            replacementArmButton,
        ]
            .forEach(evidenceStack.addArrangedSubview)
        view.addSubview(evidenceStack)

        outerScrollView.contentInsetAdjustmentBehavior = .never
        outerScrollView.translatesAutoresizingMaskIntoConstraints = false
        outerScrollView.attemptEvidenceLabel = outerAttemptLabel
        outerScrollView.movementEvidenceLabel = outerMovementLabel
        outerScrollView.onEvidenceChange = { [weak self] _ in
            self?.recordEvidence()
        }
        view.addSubview(outerScrollView)

        deepCutsLabel.text = "Deep Cuts"
        deepCutsLabel.accessibilityTraits.insert(.header)
        outerScrollView.addSubview(deepCutsLabel)

        innerScrollView.contentInsetAdjustmentBehavior = .never
        innerScrollView.attemptEvidenceLabel = innerAttemptLabel
        innerScrollView.movementEvidenceLabel = innerMovementLabel
        innerScrollView.onEvidenceChange = { [weak self] scrollView in
            guard let self else { return }
            self.targetButton.isAccessibilityElement = scrollView.contentOffset.x >= self.targetRevealOffset
            self.recordEvidence()
        }
        outerScrollView.addSubview(innerScrollView)

        let nearButton = UIButton(type: .system)
        nearButton.setTitle("Almost There", for: .normal)
        nearButton.frame = CGRect(x: 20, y: 32, width: 180, height: 96)
        innerScrollView.addSubview(nearButton)

        targetButton.setTitle("Verified by The Vibe Check", for: .normal)
        targetButton.accessibilityValue = "The Vibe Check"
        targetButton.isAccessibilityElement = false
        targetButton.addTarget(self, action: #selector(activateTarget), for: .touchUpInside)
        innerScrollView.addSubview(targetButton)

        NSLayoutConstraint.activate([
            evidenceStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            evidenceStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            evidenceStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            outerScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            outerScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            outerScrollView.topAnchor.constraint(equalTo: evidenceStack.bottomAnchor, constant: 12),
            outerScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let outerContentHeight = max(900, outerScrollView.bounds.height + 500)
        outerScrollView.contentSize = CGSize(width: outerScrollView.bounds.width, height: outerContentHeight)
        deepCutsLabel.frame = CGRect(
            x: 20,
            y: outerContentHeight - 240,
            width: 260,
            height: 30
        )
        innerScrollView.frame = CGRect(
            x: 0,
            y: outerContentHeight - 200,
            width: outerScrollView.bounds.width,
            height: 160
        )
        let innerContentWidth = max(900, innerScrollView.bounds.width + 520)
        innerScrollView.contentSize = CGSize(width: innerContentWidth, height: innerScrollView.bounds.height)
        targetButton.frame = CGRect(x: innerContentWidth - 240, y: 32, width: 220, height: 96)
        targetRevealOffset = max(1, targetButton.frame.minX - innerScrollView.bounds.width + 40)
        outerScrollView.publishEvidence()
        innerScrollView.publishEvidence()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        outerScrollView.beginEvidenceTracking()
        innerScrollView.beginEvidenceTracking()
        restorationStateLabel.accessibilityValue = "Tracking"
        recordEvidence()
    }

    // MARK: - Target Action

    @objc private func activateTarget() {
        activationCount += 1
        activationCountLabel.accessibilityValue = String(activationCount)
        selectedLabel.text = "Selected Verified"
    }

    @objc private func armScreenReplacement() {
        replacementArmed = true
        replacementModeLabel.accessibilityValue = "Armed"
    }

    // MARK: - Evidence

    private func configureEvidenceLabel(_ label: UILabel, title: String) {
        label.text = title
        label.accessibilityLabel = title
        label.accessibilityValue = "0"
    }

    private func recordEvidence() {
        guard !didReplaceScreen else { return }
        let evidence = NestedScrollScenarioEvidence(
            outerOffset: outerScrollView.offsetEvidence,
            innerOffset: innerScrollView.offsetEvidence,
            outerMovementCount: outerScrollView.offsetMovementCount,
            innerMovementCount: innerScrollView.offsetMovementCount,
            outerRestorationCount: outerScrollView.originRestorationCount,
            innerRestorationCount: innerScrollView.originRestorationCount,
            activationCount: activationCount
        )
        outerRestorationLabel.accessibilityValue = String(evidence.outerRestorationCount)
        innerRestorationLabel.accessibilityValue = String(evidence.innerRestorationCount)
        outerOffsetLabel.accessibilityValue = evidence.outerOffset
        innerOffsetLabel.accessibilityValue = evidence.innerOffset

        let bothContainersMoved = evidence.outerMovementCount > 0 && evidence.innerMovementCount > 0
        if bothContainersMoved, !emittedBothMoved {
            emittedBothMoved = true
            NestedScrollScenarioInstrumentation.record(evidence)
            if replacementArmed {
                replaceScreen(after: evidence)
                return
            }
        }

        let bothOffsetsRestored = evidence.outerRestorationCount == 1
            && evidence.innerRestorationCount == 1
        if bothOffsetsRestored, !emittedRestoration {
            emittedRestoration = true
            restorationStateLabel.accessibilityValue = "Restored"
            NestedScrollScenarioInstrumentation.record(evidence)
        }
    }

    private func replaceScreen(after evidence: NestedScrollScenarioEvidence) {
        didReplaceScreen = true
        let replacement = NestedScrollReplacementView(evidence: evidence)
        replacement.frame = view.bounds
        replacement.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(replacement)
        UIAccessibility.post(notification: .screenChanged, argument: replacement)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if view.window == nil {
            NestedScrollScenarioInstrumentation.finish()
        }
    }
}

private final class NestedScrollReplacementView: UIView {
    private let replacementScrollView = AdversarialScrollEvidenceView()
    private let contentStack = UIStackView()
    private let replacementMovementLabel = UILabel()

    init(evidence: NestedScrollScenarioEvidence) {
        super.init(frame: .zero)
        backgroundColor = .systemGroupedBackground

        let heading = UILabel()
        heading.text = "Nested replacement screen"
        heading.accessibilityTraits.insert(.header)
        let labels = [
            heading,
            evidenceLabel("Original outer restorations", value: String(evidence.outerRestorationCount)),
            evidenceLabel("Original inner restorations", value: String(evidence.innerRestorationCount)),
            evidenceLabel("Nested target activations", value: String(evidence.activationCount)),
            evidenceLabel("Replacement scroll movements", value: "0"),
            evidenceLabel("Replacement scroll offset", value: "0.00, 0.00"),
        ]
        replacementMovementLabel.text = "Replacement scroll movements"
        replacementMovementLabel.accessibilityLabel = "Replacement scroll movements"
        replacementMovementLabel.accessibilityValue = "0"
        labels.dropLast(2).forEach(contentStack.addArrangedSubview)
        contentStack.addArrangedSubview(replacementMovementLabel)
        contentStack.addArrangedSubview(labels.last!)

        replacementScrollView.movementEvidenceLabel = replacementMovementLabel
        replacementScrollView.translatesAutoresizingMaskIntoConstraints = false
        replacementScrollView.contentInsetAdjustmentBehavior = .never
        addSubview(replacementScrollView)
        replacementScrollView.addSubview(contentStack)
        contentStack.axis = .vertical
        contentStack.spacing = 8
        contentStack.frame = CGRect(x: 20, y: 24, width: 280, height: 260)

        NSLayoutConstraint.activate([
            replacementScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            replacementScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            replacementScrollView.topAnchor.constraint(equalTo: topAnchor),
            replacementScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        replacementScrollView.contentSize = CGSize(
            width: replacementScrollView.bounds.width,
            height: max(replacementScrollView.bounds.height + 400, 900)
        )
        replacementScrollView.beginEvidenceTracking()
    }

    private func evidenceLabel(_ title: String, value: String) -> UILabel {
        let label = UILabel()
        label.text = title
        label.accessibilityLabel = title
        label.accessibilityValue = value
        return label
    }
}
