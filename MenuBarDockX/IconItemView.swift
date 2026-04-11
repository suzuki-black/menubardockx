import AppKit

// MARK: - NSCollectionViewItem subclass

final class IconItemView: NSCollectionViewItem {

    static let reuseID = NSUserInterfaceItemIdentifier("IconItemView")

    var onPress: (() -> Void)?

    // MARK: Views
    private let iconView   = NSImageView()
    private let nameLabel  = NSTextField(labelWithString: "")
    private let hoverLayer = CALayer()

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        setupHover()
    }

    private func setupViews() {
        // Hover background
        hoverLayer.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        hoverLayer.cornerRadius = 10
        hoverLayer.opacity = 0
        view.layer?.addSublayer(hoverLayer)

        // Icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(iconView)

        // Label
        nameLabel.font = .systemFont(ofSize: 10, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 2
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            iconView.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),

            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
        ])

        // Click gesture
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        view.addGestureRecognizer(click)
    }

    private func setupHover() {
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(tracking)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        hoverLayer.frame = view.bounds
    }

    // MARK: - Configuration

    func configure(with item: MenuBarItem) {
        iconView.image = item.image
        let label = item.axDescription.isEmpty ? item.appName : item.axDescription
        nameLabel.stringValue = label
        view.toolTip = label
    }

    // MARK: - Interaction

    @objc private func handleClick() {
        // Brief press animation
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            view.animator().alphaValue = 0.6
        } completionHandler: { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.08
                self?.view.animator().alphaValue = 1.0
            }
            self?.onPress?()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            hoverLayer.opacity = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            hoverLayer.opacity = 0
        }
    }
}
