import TableProAutocomplete
import UIKit

final class QuerySuggestionBar: UIView {
    var onSelect: ((QuerySuggestion) -> Void)?
    private(set) var suggestions: [QuerySuggestion] = []

    private let chips = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        chips.axis = .horizontal
        chips.spacing = 8

        let row = UIStackView(arrangedSubviews: [chips, Self.makeDivider()])
        row.axis = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("QuerySuggestionBar does not support NSCoder init")
    }

    func show(_ suggestions: [QuerySuggestion]) {
        guard suggestions != self.suggestions else { return }
        self.suggestions = suggestions
        for chip in chips.arrangedSubviews {
            chip.removeFromSuperview()
        }
        for (index, suggestion) in suggestions.enumerated() {
            chips.addArrangedSubview(makeChip(for: suggestion, isTabTarget: index == 0))
        }
        isHidden = suggestions.isEmpty
    }

    static func keyConfiguration(title: String, isProminent: Bool = false) -> UIButton.Configuration {
        var config: UIButton.Configuration = isProminent ? .filled() : .gray()
        config.title = title
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attrs = incoming
            attrs.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .medium)
            return attrs
        }
        // A title that can wrap makes UIStackView give every key in a row the width of the widest.
        config.titleLineBreakMode = .byTruncatingTail
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        return config
    }

    private func makeChip(for suggestion: QuerySuggestion, isTabTarget: Bool) -> UIButton {
        let button = UIButton(
            configuration: Self.keyConfiguration(title: suggestion.label, isProminent: isTabTarget),
            primaryAction: UIAction { [weak self] _ in self?.onSelect?(suggestion) }
        )
        button.accessibilityLabel = suggestion.label
        button.accessibilityValue = Self.kindName(suggestion.kind)
        return button
    }

    private static func makeDivider() -> UIView {
        let container = UIView()
        let line = UIView()
        line.backgroundColor = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)

        let width = line.widthAnchor.constraint(
            equalToConstant: HairlineThickness.points(forDisplayScale: container.traitCollection.displayScale)
        )
        container.registerForTraitChanges([UITraitDisplayScale.self]) { (view: UIView, _) in
            width.constant = HairlineThickness.points(forDisplayScale: view.traitCollection.displayScale)
        }

        NSLayoutConstraint.activate([
            width,
            line.heightAnchor.constraint(equalTo: container.heightAnchor, multiplier: 0.5),
            line.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        return container
    }

    private static func kindName(_ kind: SQLCompletionKind) -> String {
        switch kind {
        case .keyword: String(localized: "Keyword")
        case .table: String(localized: "Table")
        case .view: String(localized: "View")
        case .column: String(localized: "Column")
        case .function: String(localized: "Function")
        case .schema: String(localized: "Schema")
        case .alias: String(localized: "Alias")
        case .operator: String(localized: "Operator")
        case .favorite: String(localized: "Favorite")
        }
    }
}
