import SwiftUI
import UIKit

struct UIKitAccessibilityValueProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> UIKitAccessibilityValueProbeView {
        UIKitAccessibilityValueProbeView()
    }

    func updateUIView(
        _ view: UIKitAccessibilityValueProbeView,
        context: Context
    ) {}
}

final class UIKitAccessibilityValueProbeView: UIView {
    private let selfUpdatingElement = HandRolledAccessibilityElement(title: "Counter")
    private let externallyUpdatedElement = HandRolledAccessibilityElement(
        title: "Remote value",
        activatesItself: false
    )
    private let externalUpdateButton = UIButton(
        configuration: .borderedProminent(),
        primaryAction: nil
    )
    private let stack = UIStackView()
    private var elementCards: [ValueCardView] = []

    private var exposedElements: [HandRolledAccessibilityElement] {
        [selfUpdatingElement, externallyUpdatedElement]
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        isAccessibilityElement = false
        accessibilityContainerType = .semanticGroup

        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        elementCards = exposedElements.map { element in
            let card = ValueCardView(title: element.title, value: element.currentValue)
            element.valueDidChange = { [weak card] value in
                card?.render(value: value)
            }
            stack.addArrangedSubview(card)
            return card
        }

        externalUpdateButton.setTitle("Update Remote Object", for: .normal)
        externalUpdateButton.accessibilityHint = "Increments the separate Remote value object"
        externalUpdateButton.addTarget(
            self,
            action: #selector(updateRemoteObject),
            for: .touchUpInside
        )
        stack.addArrangedSubview(externalUpdateButton)

        accessibilityElements = exposedElements + [externalUpdateButton]

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        for (element, card) in zip(
            exposedElements,
            elementCards
        ) {
            element.accessibilityFrame = UIAccessibility.convertToScreenCoordinates(
                card.bounds,
                in: card
            )
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let location = touch.location(in: self)
        guard let index = elementCards.firstIndex(where: { card in
            card.convert(card.bounds, to: self).contains(location)
        }) else {
            super.touchesEnded(touches, with: event)
            return
        }

        guard exposedElements[index].accessibilityActivate() else {
            super.touchesEnded(touches, with: event)
            return
        }
    }

    @objc private func updateRemoteObject() {
        externallyUpdatedElement.advanceValue()
    }
}

final class HandRolledAccessibilityElement: NSObject {
    let title: String
    var valueDidChange: (@MainActor (String) -> Void)?

    private let activatesItself: Bool
    private var count = 0

    var currentValue: String {
        count.formatted()
    }

    init(
        title: String,
        activatesItself: Bool = true
    ) {
        self.title = title
        self.activatesItself = activatesItself
        super.init()

        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityValue = currentValue
        accessibilityTraits = activatesItself ? .button : .staticText
        accessibilityHint = activatesItself ? "Increments the counter" : nil
    }

    override var description: String {
        "\(NSStringFromClass(type(of: self)))(label=\(title), value=\(currentValue))"
    }

    override func accessibilityActivate() -> Bool {
        guard activatesItself else { return false }
        advanceValue()
        return true
    }

    @MainActor
    func advanceValue() {
        count += 1
        let value = currentValue
        accessibilityValue = value
        valueDidChange?(value)
    }
}

private final class ValueCardView: UIView {
    private let valueLabel = UILabel()

    init(title: String, value: String) {
        super.init(frame: .zero)

        isAccessibilityElement = false
        accessibilityElementsHidden = true

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true

        valueLabel.font = .preferredFont(forTextStyle: .title2)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textColor = tintColor

        let labels = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        labels.axis = .vertical
        labels.spacing = 4
        labels.isUserInteractionEnabled = false
        labels.translatesAutoresizingMaskIntoConstraints = false

        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        addSubview(labels)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 72),
            labels.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            labels.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])

        render(value: value)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func render(value: String) {
        valueLabel.text = value
    }
}
