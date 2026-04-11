import AppKit

// Class wrapper so Category (a struct) can be used with objc_setAssociatedObject
private final class CategoryBox {
    let value: Category
    init(_ value: Category) { self.value = value }
}

final class CategoryTabView: NSView {

    var onSelect: ((Category) -> Void)?

    private(set) var categories: [Category] = []
    private(set) var selectedCategory: Category?

    private let scrollView = NSScrollView()
    private let stackView  = NSStackView()
    private var buttons: [TabButton] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setupViews() }

    private func setupViews() {
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stackView.orientation = .horizontal
        stackView.spacing = 6
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        scrollView.documentView = stackView

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func setCategories(_ cats: [Category], selected: Category?) {
        categories = cats
        selectedCategory = selected ?? cats.first
        rebuild()
    }

    private func rebuild() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons.removeAll()

        for cat in categories {
            let btn = TabButton(category: cat)
            btn.target = self
            btn.action = #selector(tabTapped(_:))
            stackView.addArrangedSubview(btn)
            buttons.append(btn)
        }

        stackView.frame.size = stackView.fittingSize
        updateSelection()
    }

    @objc private func tabTapped(_ sender: TabButton) {
        selectedCategory = sender.category
        updateSelection()
        onSelect?(sender.category)
    }

    private func updateSelection() {
        for btn in buttons {
            btn.setSelected(btn.category.id == selectedCategory?.id)
        }
    }
}

// MARK: - Tab button

final class TabButton: NSButton {
    let category: Category

    private let label = NSTextField(labelWithString: "")
    private let icon  = NSImageView()

    init(category: Category) {
        self.category = category
        super.init(frame: .zero)
        // Clear NSButton's default title rendering to prevent text doubling
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false

        icon.image = NSImage(systemSymbolName: category.sfSymbol, accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        label.stringValue = category.name
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: 28),
        ])

        setSelected(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ selected: Bool) {
        layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            : NSColor.clear.cgColor
        let color: NSColor = selected ? .controlAccentColor : .secondaryLabelColor
        label.textColor = color
        icon.contentTintColor = color
    }

    override var intrinsicContentSize: NSSize {
        let labelW = label.intrinsicContentSize.width
        return NSSize(width: labelW + 14 + 4 + 8 + 8, height: 28)
    }
}
