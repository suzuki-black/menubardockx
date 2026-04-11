import AppKit

final class LauncherViewController: NSViewController {

    // MARK: - Dependencies
    private let enumerator = MenuBarEnumerator()
    private let store       = DataStore.shared
    private let classifier  = ClassificationRulesManager.shared

    // MARK: - State
    private var allItems:      [MenuBarItem] = []
    private var filteredItems: [MenuBarItem] = []
    private var categories:    [Category]    = []
    private var selectedCategory: Category?
    private var searchQuery = ""

    // MARK: - Views
    private let tabView      = CategoryTabView()
    private let searchField  = NSSearchField()
    private let collectionView = NSCollectionView()
    private let scrollView     = NSScrollView()
    private let refreshButton  = NSButton()
    private let spinner        = NSProgressIndicator()

    private static let columns: CGFloat = 6
    private static let itemSize = NSSize(width: 72, height: 72)

    // MARK: - Lifecycle

    override func loadView() {
        // NSVisualEffectView provides the blur background
        let effectView = NSVisualEffectView()
        effectView.blendingMode = .behindWindow
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 18
        view = effectView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupSubviews()
        loadData()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Enumerate on background thread to avoid blocking the main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.refreshItems()
        }
    }

    // MARK: - Layout

    private func setupSubviews() {
        // ── Tab bar ───────────────────────────────────────────────────────────
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.onSelect = { [weak self] cat in
            self?.selectedCategory = cat
            self?.applyFilter()
        }
        view.addSubview(tabView)

        // ── Separator ─────────────────────────────────────────────────────────
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sep)

        // ── Collection view ───────────────────────────────────────────────────
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = Self.itemSize
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate   = self
        collectionView.register(IconItemView.self, forItemWithIdentifier: IconItemView.reuseID)
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.registerForDraggedTypes([.string])
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        // ── Spinner ───────────────────────────────────────────────────────────
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        // ── Bottom bar ────────────────────────────────────────────────────────
        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBar)

        searchField.placeholderString = "検索…"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        (searchField.cell as? NSSearchFieldCell)?.searchButtonCell?.isTransparent = true
        searchField.delegate = self
        bottomBar.addSubview(searchField)

        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "更新")
        refreshButton.isBordered = false
        refreshButton.target = self
        refreshButton.action = #selector(refreshItems)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(refreshButton)

        // ── Constraints ───────────────────────────────────────────────────────
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabView.heightAnchor.constraint(equalToConstant: 36),

            sep.topAnchor.constraint(equalTo: tabView.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            sep.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: sep.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            spinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 48),

            searchField.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 12),
            searchField.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -8),

            refreshButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -12),
            refreshButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 24),
            refreshButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    // MARK: - Data

    private func loadData() {
        // Load categories synchronously (fast, local JSON)
        categories = store.loadCategories()
        selectedCategory = categories.first
        tabView.setCategories(categories, selected: selectedCategory)
        // Items are loaded later via refreshItems() on a background thread
    }

    @objc func refreshItems() {
        DispatchQueue.main.async { self.spinner.startAnimation(nil) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let axOK = AXIsProcessTrusted()
            let savedDTOs = self.store.loadItemDTOs()
            let fresh = self.enumerator.enumerate(merging: savedDTOs)
            DispatchQueue.main.async {
                self.allItems = fresh
                self.applyAutoClassification()
                self.applyFilter()
                self.spinner.stopAnimation(nil)
                if !axOK && fresh.isEmpty {
                    self.showAccessibilityPrompt()
                }
            }
        }
    }

    private func showAccessibilityPrompt() {
        let alert = NSAlert()
        alert.messageText = "アクセシビリティ権限が必要です"
        alert.informativeText = """
            メニューバーアイコンを読み込むには、アクセシビリティ権限が必要です。

            システム設定 → プライバシーとセキュリティ → アクセシビリティ
            で MenuBarDockX を許可してから、⟳ ボタンで再読み込みしてください。
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "システム設定を開く")
        alert.addButton(withTitle: "閉じる")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
        }
    }

    /// Apply classification_rules.json auto-assignment for items without a category.
    private func applyAutoClassification() {
        var changed = false
        for i in allItems.indices where allItems[i].categoryID == nil {
            if let name = classifier.classify(bundleID: allItems[i].bundleID),
               let cat = categories.first(where: { $0.name == name }) {
                allItems[i].categoryID = cat.id
                changed = true
            }
        }
        if changed { persistItems() }
    }

    private func applyFilter() {
        let isCategoryAll = selectedCategory?.id == Category.allItems.id

        filteredItems = allItems.filter { item in
            let categoryMatch = isCategoryAll || item.categoryID == selectedCategory?.id
            let searchMatch   = searchQuery.isEmpty
                || item.appName.localizedCaseInsensitiveContains(searchQuery)
                || item.axDescription.localizedCaseInsensitiveContains(searchQuery)
            return categoryMatch && searchMatch
        }

        collectionView.reloadData()
    }

    private func persistItems() {
        let dtos = allItems.map { MenuBarItemDTO(from: $0) }
        store.saveItemDTOs(dtos)
    }

    // MARK: - Category management

    func addCategory(name: String, sfSymbol: String) {
        let cat = Category(id: UUID(), name: name, sfSymbol: sfSymbol, isBuiltin: false,
                           sortOrder: categories.count)
        categories.append(cat)
        store.saveCategories(categories)
        tabView.setCategories(categories, selected: selectedCategory)
    }

    func removeCategory(_ category: Category) {
        guard !category.isBuiltin else { return }
        // Unassign items in this category
        for i in allItems.indices where allItems[i].categoryID == category.id {
            allItems[i].categoryID = nil
        }
        categories.removeAll { $0.id == category.id }
        store.saveCategories(categories)
        persistItems()
        tabView.setCategories(categories, selected: selectedCategory)
        applyFilter()
    }

    func moveItem(_ item: MenuBarItem, toCategory category: Category?) {
        guard let idx = allItems.firstIndex(where: { $0.id == item.id }) else { return }
        allItems[idx].categoryID = category?.id
        persistItems()
        applyFilter()
    }
}

// MARK: - NSCollectionViewDataSource

extension LauncherViewController: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView,
                        numberOfItemsInSection section: Int) -> Int {
        filteredItems.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: IconItemView.reuseID, for: indexPath) as! IconItemView
        let menuItem = filteredItems[indexPath.item]
        item.configure(with: menuItem)
        item.onPress = { [weak self] in
            self?.enumerator.pressItem(menuItem)
        }
        return item
    }
}

// MARK: - NSCollectionViewDelegate (drag-and-drop for category reassignment)

extension LauncherViewController: NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView,
                        canDragItemsAt indexPaths: Set<IndexPath>,
                        with event: NSEvent) -> Bool { true }

    func collectionView(_ collectionView: NSCollectionView,
                        pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        let item = filteredItems[indexPath.item]
        return item.id.uuidString as NSString
    }
}

// MARK: - NSSearchFieldDelegate

extension LauncherViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        searchQuery = searchField.stringValue
        applyFilter()
    }
}
