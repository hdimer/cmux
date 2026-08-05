import AppKit
import CmuxExtensionSidebarExamples
import CmuxFoundation
import CmuxSidebarProviderKit

@MainActor
private final class SidebarBundledProviderDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class SidebarBundledProviderNativeViewController: NSViewController {
    private final class MoveCommand: NSObject {
        let workspaceID: UUID
        let delta: Int

        init(workspaceID: UUID, delta: Int) {
            self.workspaceID = workspaceID
            self.delta = delta
        }
    }

    private let providerID: String
    private let tabManager: TabManager
    private let onSelectWorkspace: (UUID) -> Void
    private let onNewWorkspace: () -> Void
    private let onNeedsRefresh: () -> Void

    private let scrollView = NSScrollView()
    private let documentView = SidebarBundledProviderDocumentView()
    private let contentStack = NSStackView()
    private var collapsedSectionIDs: Set<String> = []
    private var worktreeCreationSectionIDs: Set<String> = []
    private var latestSnapshot: CmuxSidebarProviderSnapshot?
    private var latestModel: CmuxSidebarProviderRenderModel?
    private var browserStackStateTask: Task<Void, Never>?

    init(
        providerID: String,
        tabManager: TabManager,
        onSelectWorkspace: @escaping (UUID) -> Void,
        onNewWorkspace: @escaping () -> Void,
        onNeedsRefresh: @escaping () -> Void
    ) {
        self.providerID = providerID
        self.tabManager = tabManager
        self.onSelectWorkspace = onSelectWorkspace
        self.onNewWorkspace = onNewWorkspace
        self.onNeedsRefresh = onNeedsRefresh
        super.init(nibName: nil, bundle: nil)

        browserStackStateTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: BrowserStackSidebar.stateDidLoadNotification
            ) {
                guard !Task.isCancelled, let self else { return }
                onNeedsRefresh()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        MainActor.assumeIsolated {
            browserStackStateTask?.cancel()
        }
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: SidebarWorkspaceScrollInsets.workspaceList.top,
            left: 0,
            bottom: SidebarWorkspaceScrollInsets.workspaceList.bottom,
            right: 0
        )
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 2
        contentStack.edgeInsets = NSEdgeInsets(
            top: SidebarWorkspaceListMetrics.rowVerticalPadding,
            left: 0,
            bottom: SidebarWorkspaceListMetrics.rowVerticalPadding + 40,
            right: 0
        )
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        scrollView.documentView = documentView
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])

        root.setAccessibilityIdentifier("sidebar.provider.\(providerID)")
        view = root
    }

    func update(snapshot: CmuxSidebarProviderSnapshot, now: Date) {
        guard let provider = CmuxExtensionSidebarSelection.provider(for: providerID) else {
            latestSnapshot = snapshot
            latestModel = nil
            replaceArrangedSubviews(with: [])
            return
        }
        let context = CmuxSidebarProviderRenderContext(now: now)
        let model: CmuxSidebarProviderRenderModel
        if let contextualProvider = provider as? any CmuxContextualSidebarProvider {
            model = contextualProvider.render(snapshot: snapshot, context: context)
        } else {
            model = provider.render(snapshot: snapshot)
        }
        latestSnapshot = snapshot
        latestModel = model
        render(model: model, snapshot: snapshot, now: now)
    }

    func teardown() {
        browserStackStateTask?.cancel()
        browserStackStateTask = nil
        latestSnapshot = nil
        latestModel = nil
        replaceArrangedSubviews(with: [])
    }

    private func render(
        model: CmuxSidebarProviderRenderModel,
        snapshot: CmuxSidebarProviderSnapshot,
        now: Date
    ) {
        let workspacesByID = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.id, $0) })
        let views: [NSView]
        switch model.presentation {
        case .tree:
            views = treeViews(
                sections: model.sections,
                providerID: model.providerId,
                workspacesByID: workspacesByID,
                selectedWorkspaceID: snapshot.selectedWorkspaceId,
                now: now
            )
        case .browserStack:
            views = browserStackViews(
                model: model,
                providerID: model.providerId,
                workspacesByID: workspacesByID,
                selectedWorkspaceID: snapshot.selectedWorkspaceId,
                now: now
            )
        }
        replaceArrangedSubviews(with: views)
    }

    private func treeViews(
        sections: [CmuxSidebarProviderSection],
        providerID: String,
        workspacesByID: [UUID: CmuxSidebarProviderWorkspace],
        selectedWorkspaceID: UUID?,
        now: Date
    ) -> [NSView] {
        sections.flatMap { section -> [NSView] in
            let isCollapsed = collapsedSectionIDs.contains(section.id)
            let header = SidebarBundledProviderSectionHeaderView(
                title: sectionTitle(section.treeSection),
                systemImageName: section.treeSection.systemImageName,
                isCollapsed: isCollapsed,
                canCreateWorktree: section.treeSection.projectRootPath != nil,
                isCreatingWorktree: worktreeCreationSectionIDs.contains(section.id),
                onToggle: { [weak self] in self?.toggleSection(section.id) },
                onCreateWorktree: { [weak self] in self?.createWorktree(for: section) }
            )
            guard !isCollapsed else { return [header] }
            return [header] + section.rows.map { row in
                workspaceRowView(
                    row: row,
                    workspace: workspacesByID[row.workspaceId],
                    providerID: providerID,
                    isSelected: row.workspaceId == selectedWorkspaceID,
                    now: now,
                    supportsReordering: false
                )
            }
        } + [SidebarBundledProviderEmptyAreaView(onActivate: onNewWorkspace)]
    }

    private func browserStackViews(
        model: CmuxSidebarProviderRenderModel,
        providerID: String,
        workspacesByID: [UUID: CmuxSidebarProviderWorkspace],
        selectedWorkspaceID: UUID?,
        now: Date
    ) -> [NSView] {
        let allRows = model.sections.flatMap(\.rows)
        let tileRows = model.sections.first { $0.id == "tiles" }?.rows
            ?? Array(allRows.prefix(3))
        let looseRows = model.sections.first { $0.id == "loose" }?.rows
            ?? Array(allRows.dropFirst(3).prefix(5))
        let groups = model.sections.filter {
            $0.id != "tiles" && $0.id != "loose" && !$0.rows.isEmpty
        }
        var views: [NSView] = []
        if !tileRows.isEmpty {
            views.append(browserTileGrid(
                rows: tileRows,
                selectedWorkspaceID: selectedWorkspaceID
            ))
        }
        views.append(contentsOf: looseRows.map { row in
            workspaceRowView(
                row: row,
                workspace: workspacesByID[row.workspaceId],
                providerID: providerID,
                isSelected: row.workspaceId == selectedWorkspaceID,
                now: now,
                supportsReordering: true
            )
        })
        for section in groups {
            views.append(SidebarBundledProviderSectionHeaderView(
                title: sectionTitle(section.treeSection),
                systemImageName: section.treeSection.systemImageName,
                isCollapsed: false,
                canCreateWorktree: false,
                isCreatingWorktree: false,
                onToggle: nil,
                onCreateWorktree: nil
            ))
            views.append(contentsOf: section.rows.map { row in
                workspaceRowView(
                    row: row,
                    workspace: workspacesByID[row.workspaceId],
                    providerID: providerID,
                    isSelected: row.workspaceId == selectedWorkspaceID,
                    now: now,
                    supportsReordering: true
                )
            })
        }
        views.append(SidebarBundledProviderNewWorkspaceButton(onActivate: onNewWorkspace))
        views.append(SidebarBundledProviderEmptyAreaView(onActivate: onNewWorkspace))
        return views
    }

    private func browserTileGrid(
        rows: [CmuxSidebarProviderRow],
        selectedWorkspaceID: UUID?
    ) -> NSView {
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.xPlacement = .fill
        grid.yPlacement = .fill
        grid.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 4, right: 8)
        grid.translatesAutoresizingMaskIntoConstraints = false

        for start in stride(from: 0, to: rows.count, by: 3) {
            var rowViews = Array(rows[start ..< min(start + 3, rows.count)]).map { row in
                SidebarBundledProviderTileView(
                    row: row,
                    isSelected: row.workspaceId == selectedWorkspaceID,
                    onActivate: { [weak self] in self?.onSelectWorkspace(row.workspaceId) }
                ) as NSView
            }
            while rowViews.count < 3 {
                rowViews.append(NSView())
            }
            let gridRow = grid.addRow(with: rowViews)
            gridRow.height = 54
        }
        return grid
    }

    private func workspaceRowView(
        row: CmuxSidebarProviderRow,
        workspace: CmuxSidebarProviderWorkspace?,
        providerID: String,
        isSelected: Bool,
        now: Date,
        supportsReordering: Bool
    ) -> CmuxExtensionSidebarWorkspaceRowNativeView {
        let view = CmuxExtensionSidebarWorkspaceRowNativeView()
        view.update(
            row: row,
            workspace: workspace,
            providerID: providerID,
            relativeNow: now,
            isSelected: isSelected,
            onSelect: onSelectWorkspace,
            onOpenWindow: CmuxExtensionSidebarInspectorWindowController.show
        )
        guard supportsReordering else { return view }
        let menu = NSMenu()
        menu.addItem(moveMenuItem(
            title: String(localized: "contextMenu.moveUp", defaultValue: "Move Up"),
            workspaceID: row.workspaceId,
            delta: -1
        ))
        menu.addItem(moveMenuItem(
            title: String(localized: "contextMenu.moveDown", defaultValue: "Move Down"),
            workspaceID: row.workspaceId,
            delta: 1
        ))
        view.menu = menu
        view.setAccessibilityHelp(String(
            localized: "sidebar.workspace.accessibilityHint",
            defaultValue: "Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions."
        ))
        return view
    }

    private func moveMenuItem(title: String, workspaceID: UUID, delta: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(moveWorkspace(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = MoveCommand(workspaceID: workspaceID, delta: delta)
        return item
    }

    @objc private func moveWorkspace(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? MoveCommand,
              let model = latestModel else {
            NSSound.beep()
            return
        }
        let orderedRows = model.sections.flatMap { section in
            section.rows.map {
                ExtensionSidebarBrowserStackDropRow(
                    workspaceId: $0.workspaceId,
                    sectionId: section.id
                )
            }
        }
        guard let currentIndex = orderedRows.firstIndex(where: {
            $0.workspaceId == command.workspaceID
        }) else {
            NSSound.beep()
            return
        }
        let targetIndex = min(max(currentIndex + command.delta, 0), orderedRows.count - 1)
        guard targetIndex != currentIndex else { return }
        let insertionPosition = command.delta > 0 ? targetIndex + 1 : targetIndex
        guard let move = ExtensionSidebarBrowserStackDropPlanner(orderedRows: orderedRows).move(
            draggedWorkspaceId: command.workspaceID,
            insertionPosition: insertionPosition
        ), handleMutation(.moveWorkspace(move)) else {
            NSSound.beep()
            return
        }
    }

    private func handleMutation(_ mutation: CmuxSidebarProviderMutation) -> Bool {
        guard let snapshot = latestSnapshot,
              let provider = CmuxExtensionSidebarSelection.provider(for: providerID)
                as? any CmuxMutableSidebarProvider else {
            return false
        }
        do {
            let result = try provider.handle(mutation, snapshot: snapshot)
            if result.ok { onNeedsRefresh() }
            return result.ok
        } catch {
#if DEBUG
            cmuxDebugLog(
                "sidebar.provider.mutation.failed provider=\(providerID) " +
                "error=\(error.localizedDescription)"
            )
#endif
            return false
        }
    }

    private func toggleSection(_ sectionID: String) {
        if !collapsedSectionIDs.remove(sectionID) {
            collapsedSectionIDs.insert(sectionID)
        }
        onNeedsRefresh()
    }

    private func createWorktree(for section: CmuxSidebarProviderSection) {
        guard let projectRootPath = section.treeSection.projectRootPath,
              !worktreeCreationSectionIDs.contains(section.id) else {
            return
        }
        worktreeCreationSectionIDs.insert(section.id)
        onNeedsRefresh()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                worktreeCreationSectionIDs.remove(section.id)
                onNeedsRefresh()
            }
            do {
                let result = try await CmuxExtensionWorktreePrototype.createWorktree(
                    projectRootPath: projectRootPath
                )
                let spawn = result.workspaceSpawnArgs()
                tabManager.addWorkspace(
                    title: spawn.title,
                    titleSource: .auto,
                    workingDirectory: spawn.workingDirectory,
                    initialTerminalInput: spawn.initialTerminalInput,
                    inheritWorkingDirectory: spawn.inheritWorkingDirectory,
                    select: true,
                    eagerLoadTerminal: false,
                    autoWelcomeIfNeeded: spawn.initialTerminalInput == nil
                )
            } catch {
                NSSound.beep()
#if DEBUG
                cmuxDebugLog(
                    "sidebar.provider.worktree.failed project=\(projectRootPath) " +
                    "error=\(error.localizedDescription)"
                )
#endif
            }
        }
    }

    private func sectionTitle(_ section: CmuxSidebarProviderTreeSection) -> String {
        section.titleText.map(CmuxExtensionSidebarSelection.localizedText) ?? section.title
    }

    private func replaceArrangedSubviews(with views: [NSView]) {
        for arrangedView in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
    }
}

@MainActor
private final class SidebarBundledProviderSectionHeaderView: NSView {
    init(
        title: String,
        systemImageName: String,
        isCollapsed: Bool,
        canCreateWorktree: Bool,
        isCreatingWorktree: Bool,
        onToggle: (() -> Void)?,
        onCreateWorktree: (() -> Void)?
    ) {
        super.init(frame: .zero)

        let toggleButton = SidebarBundledProviderActionButton(action: onToggle)
        toggleButton.isBordered = false
        toggleButton.imagePosition = .imageLeading
        toggleButton.alignment = .left
        toggleButton.font = .systemFont(ofSize: 12, weight: .regular)
        toggleButton.contentTintColor = .secondaryLabelColor
        toggleButton.title = title
        toggleButton.image = NSImage(
            systemSymbolName: isCollapsed ? "folder" : systemImageName,
            accessibilityDescription: nil
        )
        toggleButton.toolTip = onToggle == nil ? nil : String(
            localized: "sidebar.extension.toggleSection",
            defaultValue: "Toggle section"
        )
        toggleButton.setAccessibilityLabel(title)
        toggleButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toggleButton.isEnabled = onToggle != nil

        let createButton = SidebarBundledProviderActionButton(action: onCreateWorktree)
        createButton.isBordered = false
        createButton.imagePosition = .imageOnly
        createButton.image = NSImage(
            systemSymbolName: isCreatingWorktree ? "clock" : "plus",
            accessibilityDescription: nil
        )
        createButton.toolTip = String(
            localized: "sidebar.extension.createWorktree",
            defaultValue: "Create worktree"
        )
        createButton.setAccessibilityLabel(createButton.toolTip)
        createButton.isEnabled = canCreateWorktree && !isCreatingWorktree
        createButton.isHidden = !canCreateWorktree

        let stack = NSStackView(views: [toggleButton, createButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            createButton.widthAnchor.constraint(equalToConstant: 18),
            createButton.heightAnchor.constraint(equalToConstant: 18),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class SidebarBundledProviderActionButton: NSButton {
    private let handler: (() -> Void)?

    init(action: (() -> Void)?) {
        self.handler = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(invoke)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        handler?()
    }
}

@MainActor
private final class SidebarBundledProviderIconView: NSView {
    private let imageView = NSImageView()
    private let textLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        textLabel.alignment = .center
        textLabel.font = .systemFont(ofSize: 13, weight: .bold)
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        addSubview(textLabel)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.58),
            imageView.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.58),
            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(icon: CmuxSidebarProviderIcon?, size: CGFloat) {
        let foreground = icon?.foregroundColorHex.flatMap { NSColor(hex: $0) } ?? .labelColor
        let background = icon?.backgroundColorHex.flatMap { NSColor(hex: $0) }
            ?? NSColor.labelColor.withAlphaComponent(0.16)
        layer?.backgroundColor = background.cgColor
        layer?.cornerRadius = icon?.shape == .roundedRectangle ? size * 0.24 : size / 2
        imageView.image = icon?.systemImageName.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }
        imageView.contentTintColor = foreground
        imageView.isHidden = imageView.image == nil
        textLabel.stringValue = icon?.text ?? (imageView.image == nil ? "." : "")
        textLabel.textColor = foreground
        textLabel.isHidden = textLabel.stringValue.isEmpty
    }
}

@MainActor
private final class SidebarBundledProviderTileView: NSView {
    private let onActivate: () -> Void

    init(row: CmuxSidebarProviderRow, isSelected: Bool, onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = isSelected
            ? NSColor.labelColor.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
            : NSColor.labelColor.withAlphaComponent(0.08).cgColor

        let iconView = SidebarBundledProviderIconView()
        iconView.update(icon: row.leadingIcon, size: 26)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: row.title)
        label.alignment = .center
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),
            heightAnchor.constraint(equalToConstant: 54),
        ])
        toolTip = row.title
        setAccessibilityRole(.button)
        setAccessibilityLabel(row.title)
        setAccessibilityIdentifier("extensionSidebar.workspace.\(row.workspaceId.uuidString)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        onActivate()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

@MainActor
private final class SidebarBundledProviderNewWorkspaceButton: NSView {
    init(onActivate: @escaping () -> Void) {
        super.init(frame: .zero)
        let button = SidebarBundledProviderActionButton(action: onActivate)
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.font = .systemFont(ofSize: 13, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.title = String(localized: "sidebar.browserStack.newTab", defaultValue: "New Tab")
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        button.toolTip = button.title
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            button.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class SidebarBundledProviderEmptyAreaView: NSView {
    private let onActivate: () -> Void

    init(onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(
            localized: "sidebar.browserStack.newTab",
            defaultValue: "New Tab"
        ))
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        onActivate()
    }
}
