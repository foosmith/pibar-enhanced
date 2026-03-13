//
//  SyncSettingsViewController.swift
//  PiBar
//
//  Created by Codex on 3/12/26.
//

import Cocoa

protocol SyncSettingsViewControllerDelegate: AnyObject {
    func syncSettingsUpdated()
    func syncNowRequestedFromSettings()
}

final class SyncSettingsViewController: NSViewController {
    weak var delegate: SyncSettingsViewControllerDelegate?

    private let syncEnabledCheckbox = NSButton(checkboxWithTitle: "Enable Primary → Secondary Sync", target: nil, action: nil)
    private let setupHelperLabel = SyncSettingsViewController.makeHelperLabel("Choose the source Pi-hole and the destination Pi-hole that should mirror it.")

    private let primaryLabel = NSTextField(labelWithString: "Primary")
    private let primaryPopup = NSPopUpButton()
    private let secondaryLabel = NSTextField(labelWithString: "Secondary")
    private let secondaryPopup = NSPopUpButton()

    private let intervalLabel = NSTextField(labelWithString: "Interval")
    private let intervalPresetPopup = NSPopUpButton()
    private let intervalField = NSTextField()
    private let intervalUnitsLabel = NSTextField(labelWithString: "minutes")

    private let scopeLabel = NSTextField(labelWithString: "What to sync")
    private let syncGroupsCheckbox = NSButton(checkboxWithTitle: "Groups", target: nil, action: nil)
    private let syncAdlistsCheckbox = NSButton(checkboxWithTitle: "Adlists", target: nil, action: nil)
    private let syncDomainsCheckbox = NSButton(checkboxWithTitle: "Domains", target: nil, action: nil)
    private let dryRunCheckbox = NSButton(checkboxWithTitle: "Preview only (dry run)", target: nil, action: nil)
    private let behaviorHelperLabel = SyncSettingsViewController.makeHelperLabel("Turn off any scope you do not want reconciled. Dry run computes changes without writing to the secondary.")

    private let wipeSecondaryCheckbox = NSButton(checkboxWithTitle: "Wipe secondary adlists before sync", target: nil, action: nil)
    private let safetyHelperLabel = SyncSettingsViewController.makeWarningLabel("Use this only when you want the secondary rebuilt from scratch. Blocking may temporarily drop until gravity finishes.")

    private let summaryLabel = NSTextField(labelWithString: "")
    private let lastSyncLabel = NSTextField(labelWithString: "")
    private let logToggleCheckbox = NSButton(checkboxWithTitle: "Show activity log", target: nil, action: nil)
    private let logScrollView = NSScrollView()
    private let logTextView = NSTextView()
    private var logHeightConstraint: NSLayoutConstraint?
    private var isSyncInProgress = false

    private let syncNowButton = NSButton(title: "Sync Now", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)

    private let presetIntervals = [5, 15, 30, 60]

    private var v6Connections: [PiholeConnectionV3] {
        Preferences.standard.piholes.filter(\.isV6)
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 560))
        container.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.maximumNumberOfLines = 3

        let summaryCard = Self.makeSection(title: "Status")
        summaryCard.stack.addArrangedSubview(summaryLabel)

        syncEnabledCheckbox.target = self
        syncEnabledCheckbox.action = #selector(syncEnabledChanged)
        primaryPopup.target = self
        primaryPopup.action = #selector(primaryChanged)
        secondaryPopup.target = self
        secondaryPopup.action = #selector(secondaryChanged)
        intervalPresetPopup.target = self
        intervalPresetPopup.action = #selector(intervalPresetChanged)
        intervalField.target = self
        intervalField.action = #selector(intervalChanged)
        syncGroupsCheckbox.target = self
        syncGroupsCheckbox.action = #selector(scopeChanged)
        syncAdlistsCheckbox.target = self
        syncAdlistsCheckbox.action = #selector(scopeChanged)
        syncDomainsCheckbox.target = self
        syncDomainsCheckbox.action = #selector(scopeChanged)
        dryRunCheckbox.target = self
        dryRunCheckbox.action = #selector(dryRunChanged)
        wipeSecondaryCheckbox.target = self
        wipeSecondaryCheckbox.action = #selector(wipeSecondaryChanged)
        logToggleCheckbox.target = self
        logToggleCheckbox.action = #selector(logToggleChanged)
        syncNowButton.target = self
        syncNowButton.action = #selector(syncNowPressed)
        closeButton.target = self
        closeButton.action = #selector(closePressed)

        intervalField.alignment = .right
        intervalField.placeholderString = "Custom"
        intervalField.controlSize = .small
        intervalPresetPopup.controlSize = .small
        primaryPopup.controlSize = .small
        secondaryPopup.controlSize = .small
        syncNowButton.bezelStyle = .rounded
        closeButton.bezelStyle = .rounded

        intervalPresetPopup.addItems(withTitles: presetIntervals.map { "\($0) min" } + ["Custom"])

        let setupCard = Self.makeSection(title: "Setup")
        setupCard.stack.addArrangedSubview(syncEnabledCheckbox)
        setupCard.stack.addArrangedSubview(setupHelperLabel)
        setupCard.stack.addArrangedSubview(makeSetupGrid())

        let behaviorCard = Self.makeSection(title: "Behavior")
        behaviorCard.stack.addArrangedSubview(makeBehaviorGrid())
        behaviorCard.stack.addArrangedSubview(makeScopeRow())
        behaviorCard.stack.addArrangedSubview(dryRunCheckbox)
        behaviorCard.stack.addArrangedSubview(behaviorHelperLabel)

        let safetyCard = Self.makeSection(title: "Safety")
        safetyCard.stack.addArrangedSubview(wipeSecondaryCheckbox)
        safetyCard.stack.addArrangedSubview(safetyHelperLabel)

        let activityCard = Self.makeSection(title: "Activity")
        lastSyncLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        lastSyncLabel.lineBreakMode = .byWordWrapping
        lastSyncLabel.maximumNumberOfLines = 4
        logToggleCheckbox.setButtonType(.switch)
        activityCard.stack.addArrangedSubview(lastSyncLabel)
        activityCard.stack.addArrangedSubview(logToggleCheckbox)

        configureLogView()
        activityCard.stack.addArrangedSubview(logScrollView)

        let contentStack = NSStackView(views: [
            summaryCard.box,
            setupCard.box,
            behaviorCard.box,
            safetyCard.box,
            activityCard.box,
        ])
        contentStack.orientation = NSUserInterfaceLayoutOrientation.vertical
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [syncNowButton, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY
        buttons.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(contentStack)
        container.addSubview(buttons)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            buttons.topAnchor.constraint(equalTo: contentStack.bottomAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
        ])

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sync Settings"
        preferredContentSize = NSSize(width: 780, height: 560)
        NotificationCenter.default.addObserver(self, selector: #selector(handleSyncProgress(_:)), name: .piBarSyncProgress, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleSyncBegan), name: .piBarSyncBegan, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleSyncEnded), name: .piBarSyncEnded, object: nil)
        refreshUI()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if let window = view.window {
            window.setContentSize(preferredContentSize)
            window.minSize = preferredContentSize
        }
    }

    private func makeSetupGrid() -> NSGridView {
        let grid = NSGridView(views: [
            [primaryLabel, primaryPopup],
            [secondaryLabel, secondaryPopup],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.xPlacement = .fill
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .fill
        [primaryLabel, secondaryLabel].forEach {
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }
        [primaryPopup, secondaryPopup].forEach {
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        return grid
    }

    private func makeBehaviorGrid() -> NSGridView {
        let intervalRow = NSStackView(views: [intervalPresetPopup, intervalField, intervalUnitsLabel])
        intervalRow.orientation = .horizontal
        intervalRow.spacing = 8
        intervalRow.alignment = .centerY
        intervalField.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let grid = NSGridView(views: [
            [intervalLabel, intervalRow],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.xPlacement = .fill
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .fill
        intervalLabel.setContentHuggingPriority(.required, for: .horizontal)
        return grid
    }

    private func makeScopeRow() -> NSStackView {
        let row = NSStackView(views: [scopeLabel, syncGroupsCheckbox, syncAdlistsCheckbox, syncDomainsCheckbox])
        row.orientation = .horizontal
        row.spacing = 14
        row.alignment = .centerY
        scopeLabel.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func configureLogView() {
        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        logTextView.textContainerInset = NSSize(width: 6, height: 6)

        logScrollView.translatesAutoresizingMaskIntoConstraints = false
        logScrollView.documentView = logTextView
        logScrollView.hasVerticalScroller = true
        logScrollView.borderType = .bezelBorder
        logScrollView.drawsBackground = false

        logHeightConstraint = logScrollView.heightAnchor.constraint(equalToConstant: 0)
        logHeightConstraint?.isActive = true
        logScrollView.isHidden = true
    }

    private func refreshUI() {
        let hasAtLeastTwo = v6Connections.count >= 2

        syncEnabledCheckbox.state = Preferences.standard.syncEnabled ? .on : .off
        wipeSecondaryCheckbox.state = Preferences.standard.syncWipeSecondaryBeforeSync ? .on : .off
        syncGroupsCheckbox.state = Preferences.standard.syncSkipGroups ? .off : .on
        syncAdlistsCheckbox.state = Preferences.standard.syncSkipAdlists ? .off : .on
        syncDomainsCheckbox.state = Preferences.standard.syncSkipDomains ? .off : .on
        dryRunCheckbox.state = Preferences.standard.syncDryRunEnabled ? .on : .off

        populatePopups()
        applyStoredSelection(to: primaryPopup, identifier: Preferences.standard.syncPrimaryIdentifier)
        applyStoredSelection(to: secondaryPopup, identifier: Preferences.standard.syncSecondaryIdentifier)
        configureIntervalControls()

        let syncEnabled = syncEnabledCheckbox.state == .on
        let controlsEnabled = hasAtLeastTwo && syncEnabled && !isSyncInProgress

        [primaryPopup, secondaryPopup, intervalPresetPopup, intervalField, wipeSecondaryCheckbox, syncGroupsCheckbox, syncAdlistsCheckbox, syncDomainsCheckbox, dryRunCheckbox].forEach {
            $0.isEnabled = controlsEnabled
        }
        syncEnabledCheckbox.isEnabled = hasAtLeastTwo && !isSyncInProgress

        validateSelection()
        updateReadinessSummary()
        updateLastSyncLabel()
        updateLogVisibility()
        syncNowButton.isEnabled = isReadyToSync
    }

    private var isReadyToSync: Bool {
        v6Connections.count >= 2 &&
        syncEnabledCheckbox.state == .on &&
        !isSyncInProgress &&
        !selectedIdentifier(from: primaryPopup).isEmpty &&
        !selectedIdentifier(from: secondaryPopup).isEmpty &&
        selectedIdentifier(from: primaryPopup) != selectedIdentifier(from: secondaryPopup)
    }

    private func updateReadinessSummary() {
        summaryLabel.stringValue = readinessSummaryText()
    }

    private func readinessSummaryText() -> String {
        if isSyncInProgress {
            return "Sync is currently running. PiBar will re-enable controls when the job completes."
        }

        if v6Connections.count < 2 {
            let count = v6Connections.count
            if count == 0 {
                return "Add two Pi-hole v6 connections to enable sync."
            }
            return "Add one more Pi-hole v6 connection to enable sync."
        }

        if syncEnabledCheckbox.state != .on {
            return "Sync is off. Turn it on to choose a primary, a secondary, and an interval."
        }

        let primary = selectedIdentifier(from: primaryPopup)
        let secondary = selectedIdentifier(from: secondaryPopup)

        if primary.isEmpty || secondary.isEmpty {
            return "Choose both a primary and a secondary Pi-hole to finish setup."
        }

        if primary == secondary {
            return "Primary and secondary must be different Pi-holes."
        }

        let interval = resolvedIntervalMinutes()
        let dryRunSuffix = dryRunCheckbox.state == .on ? " in dry-run mode" : ""
        return "Ready to sync every \(interval) minutes\(dryRunSuffix)."
    }

    private func updateLastSyncLabel() {
        if let last = Preferences.standard.syncLastRunAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let status = Preferences.standard.syncLastStatus
            let message = Preferences.standard.syncLastMessage
            let statusText = status.isEmpty ? "Last sync" : "Last sync (\(status))"
            if message.isEmpty {
                lastSyncLabel.stringValue = "\(statusText): \(formatter.string(from: last))"
            } else {
                lastSyncLabel.stringValue = "\(statusText): \(formatter.string(from: last))\n\(message)"
            }
        } else if isSyncInProgress {
            lastSyncLabel.stringValue = "Current activity: sync in progress."
        } else {
            lastSyncLabel.stringValue = "No sync run yet."
        }
    }

    private func updateLogVisibility() {
        let showLog = logToggleCheckbox.state == .on
        logScrollView.isHidden = !showLog
        logHeightConstraint?.constant = showLog ? 140 : 0
    }

    private func configureIntervalControls() {
        let interval = Preferences.standard.syncIntervalMinutes
        if let presetIndex = presetIntervals.firstIndex(of: interval) {
            intervalPresetPopup.selectItem(at: presetIndex)
            intervalField.isHidden = true
            intervalUnitsLabel.isHidden = true
            intervalField.stringValue = ""
        } else {
            intervalPresetPopup.selectItem(at: presetIntervals.count)
            intervalField.isHidden = false
            intervalUnitsLabel.isHidden = false
            intervalField.stringValue = "\(interval)"
        }
    }

    private func populatePopups() {
        primaryPopup.removeAllItems()
        secondaryPopup.removeAllItems()

        for connection in v6Connections {
            let title = displayTitle(for: connection)
            let identifier = connection.identifier

            [primaryPopup, secondaryPopup].forEach { popup in
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.representedObject = identifier
                item.toolTip = identifier
                popup.menu?.addItem(item)
            }
        }
    }

    private func displayTitle(for connection: PiholeConnectionV3) -> String {
        let scheme = connection.useSSL ? "https" : "http"
        return "\(connection.hostname) (\(scheme):\(connection.port))"
    }

    private func applyStoredSelection(to popup: NSPopUpButton, identifier: String) {
        guard !identifier.isEmpty else { return }
        for item in popup.itemArray {
            if let represented = item.representedObject as? String, represented == identifier {
                popup.select(item)
                return
            }
        }
    }

    private func selectedIdentifier(from popup: NSPopUpButton) -> String {
        popup.selectedItem?.representedObject as? String ?? ""
    }

    private func resolvedIntervalMinutes() -> Int {
        let selectedIndex = intervalPresetPopup.indexOfSelectedItem
        if presetIntervals.indices.contains(selectedIndex) {
            return presetIntervals[selectedIndex]
        }

        if let minutes = Int(intervalField.stringValue), minutes >= 5 {
            return minutes
        }

        return Preferences.standard.syncIntervalMinutes
    }

    private func validateSelection() {
        let primary = selectedIdentifier(from: primaryPopup)
        let secondary = selectedIdentifier(from: secondaryPopup)
        guard !primary.isEmpty, primary == secondary, secondaryPopup.numberOfItems > 1 else { return }

        for item in secondaryPopup.itemArray {
            guard let represented = item.representedObject as? String else { continue }
            if represented != primary {
                secondaryPopup.select(item)
                break
            }
        }

        Preferences.standard.set(syncSecondaryIdentifier: selectedIdentifier(from: secondaryPopup))
    }

    @objc private func handleSyncProgress(_ notification: Notification) {
        guard let message = notification.userInfo?[SyncProgress.messageKey] as? String else { return }
        appendLog(message)
    }

    @objc private func handleSyncBegan() {
        isSyncInProgress = true
        appendLog("— sync started —")
        refreshUI()
    }

    @objc private func handleSyncEnded() {
        isSyncInProgress = false
        appendLog("— sync ended —")
        refreshUI()
    }

    private func appendLog(_ line: String) {
        let prefix = logTextView.string.isEmpty ? "" : "\n"
        logTextView.string += "\(prefix)\(line)"
        logTextView.scrollToEndOfDocument(nil)
    }

    private func clearLog() {
        logTextView.string = ""
    }

    private func persistSelections() {
        Preferences.standard.set(syncEnabled: syncEnabledCheckbox.state == .on)
        Preferences.standard.set(syncWipeSecondaryBeforeSync: wipeSecondaryCheckbox.state == .on)
        Preferences.standard.set(syncSkipGroups: syncGroupsCheckbox.state == .off)
        Preferences.standard.set(syncSkipAdlists: syncAdlistsCheckbox.state == .off)
        Preferences.standard.set(syncSkipDomains: syncDomainsCheckbox.state == .off)
        Preferences.standard.set(syncDryRunEnabled: dryRunCheckbox.state == .on)
        Preferences.standard.set(syncPrimaryIdentifier: selectedIdentifier(from: primaryPopup))
        Preferences.standard.set(syncSecondaryIdentifier: selectedIdentifier(from: secondaryPopup))
        Preferences.standard.set(syncIntervalMinutes: max(5, resolvedIntervalMinutes()))
        delegate?.syncSettingsUpdated()
    }

    @objc private func syncEnabledChanged() {
        persistSelections()
        refreshUI()
    }

    @objc private func primaryChanged() {
        persistSelections()
        refreshUI()
    }

    @objc private func secondaryChanged() {
        persistSelections()
        refreshUI()
    }

    @objc private func intervalPresetChanged() {
        if intervalPresetPopup.indexOfSelectedItem < presetIntervals.count {
            intervalField.stringValue = ""
        } else if intervalField.stringValue.isEmpty {
            intervalField.stringValue = "\(Preferences.standard.syncIntervalMinutes)"
        }
        persistSelections()
        refreshUI()
    }

    @objc private func intervalChanged() {
        persistSelections()
        refreshUI()
    }

    @objc private func scopeChanged() {
        persistSelections()
        refreshUI()
    }

    @objc private func dryRunChanged() {
        persistSelections()
        refreshUI()
    }

    @objc private func wipeSecondaryChanged() {
        if wipeSecondaryCheckbox.state == .on {
            confirmEnableWipe()
        } else {
            persistSelections()
            refreshUI()
        }
    }

    @objc private func logToggleChanged() {
        updateLogVisibility()
    }

    private func confirmEnableWipe() {
        guard let window = view.window else {
            persistSelections()
            refreshUI()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Enable destructive pre-clean?"
        alert.informativeText = "PiBar will remove or disable adlists on the secondary before rebuilding them from the primary, and gravity may take time to finish afterward."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response != .alertFirstButtonReturn {
                self.wipeSecondaryCheckbox.state = .off
            }
            self.persistSelections()
            self.refreshUI()
        }
    }

    @objc private func syncNowPressed() {
        persistSelections()
        clearLog()
        appendLog("Sync Now: requested")
        delegate?.syncNowRequestedFromSettings()
    }

    @objc private func closePressed() {
        dismiss(self)
    }

    private static func makeSection(title: String) -> (box: NSBox, stack: NSStackView) {
        let box = NSBox()
        box.title = title
        box.titlePosition = .atTop
        box.boxType = .custom
        box.cornerRadius = 8
        box.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.contentView!.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor, constant: -12),
        ])

        return (box, stack)
    }

    private static func makeHelperLabel(_ string: String) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        return label
    }

    private static func makeWarningLabel(_ string: String) -> NSTextField {
        let label = makeHelperLabel(string)
        label.textColor = .systemOrange
        return label
    }
}
