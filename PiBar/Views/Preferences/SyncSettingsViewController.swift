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
    private let primaryLabel = NSTextField(labelWithString: "Primary")
    private let primaryPopup = NSPopUpButton()
    private let secondaryLabel = NSTextField(labelWithString: "Secondary")
    private let secondaryPopup = NSPopUpButton()
    private let intervalLabel = NSTextField(labelWithString: "Interval (minutes)")
    private let intervalField = NSTextField()
    private let wipeSecondaryCheckbox = NSButton(checkboxWithTitle: "Wipe secondary adlists before sync (destructive)", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let logScrollView = NSScrollView()
    private let logTextView = NSTextView()

    private let syncNowButton = NSButton(title: "Sync Now", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)

    private var v6Connections: [PiholeConnectionV3] {
        Preferences.standard.piholes.filter(\.isV6)
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 360))

        primaryPopup.translatesAutoresizingMaskIntoConstraints = false
        secondaryPopup.translatesAutoresizingMaskIntoConstraints = false
        intervalField.translatesAutoresizingMaskIntoConstraints = false
        wipeSecondaryCheckbox.translatesAutoresizingMaskIntoConstraints = false
        syncEnabledCheckbox.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        logScrollView.translatesAutoresizingMaskIntoConstraints = false
        logTextView.translatesAutoresizingMaskIntoConstraints = false
        syncNowButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        intervalField.alignment = .right
        intervalField.placeholderString = "15"

        syncNowButton.bezelStyle = .rounded
        closeButton.bezelStyle = .rounded

        if let cell = syncEnabledCheckbox.cell as? NSButtonCell {
            cell.lineBreakMode = .byClipping
        }

        syncEnabledCheckbox.target = self
        syncEnabledCheckbox.action = #selector(syncEnabledChanged)

        primaryPopup.target = self
        primaryPopup.action = #selector(primaryChanged)

        secondaryPopup.target = self
        secondaryPopup.action = #selector(secondaryChanged)

        intervalField.target = self
        intervalField.action = #selector(intervalChanged)

        wipeSecondaryCheckbox.target = self
        wipeSecondaryCheckbox.action = #selector(wipeSecondaryChanged)

        syncNowButton.target = self
        syncNowButton.action = #selector(syncNowPressed)

        closeButton.target = self
        closeButton.action = #selector(closePressed)

        let grid = NSGridView(views: [
            [primaryLabel, primaryPopup],
            [secondaryLabel, secondaryPopup],
            [intervalLabel, intervalField],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.xPlacement = .fill
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .fill

        primaryPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        primaryPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        secondaryPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        secondaryPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        primaryLabel.setContentHuggingPriority(.required, for: .horizontal)
        secondaryLabel.setContentHuggingPriority(.required, for: .horizontal)
        intervalLabel.setContentHuggingPriority(.required, for: .horizontal)

        let buttons = NSStackView(views: [syncNowButton, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY
        buttons.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.isSelectable = true
        statusLabel.allowsEditingTextAttributes = true

        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        logTextView.textContainerInset = NSSize(width: 6, height: 6)
        logScrollView.documentView = logTextView
        logScrollView.hasVerticalScroller = true
        logScrollView.borderType = .bezelBorder
        logScrollView.drawsBackground = false

        container.addSubview(syncEnabledCheckbox)
        container.addSubview(grid)
        container.addSubview(wipeSecondaryCheckbox)
        container.addSubview(statusLabel)
        container.addSubview(logScrollView)
        container.addSubview(buttons)

        NSLayoutConstraint.activate([
            syncEnabledCheckbox.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            syncEnabledCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            syncEnabledCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),

            grid.topAnchor.constraint(equalTo: syncEnabledCheckbox.bottomAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            intervalField.widthAnchor.constraint(equalToConstant: 80),

            wipeSecondaryCheckbox.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 10),
            wipeSecondaryCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            wipeSecondaryCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),

            statusLabel.topAnchor.constraint(equalTo: wipeSecondaryCheckbox.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            logScrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            logScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            logScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            logScrollView.heightAnchor.constraint(equalToConstant: 110),

            buttons.topAnchor.constraint(equalTo: logScrollView.bottomAnchor, constant: 14),
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
        ])

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sync Settings"
        preferredContentSize = NSSize(width: 760, height: 360)
        NotificationCenter.default.addObserver(self, selector: #selector(handleSyncProgress(_:)), name: .piBarSyncProgress, object: nil)
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

    private func displayTitle(for connection: PiholeConnectionV3) -> String {
        let scheme = connection.useSSL ? "https" : "http"
        return "\(connection.hostname) (\(scheme):\(connection.port))"
    }

    private func populatePopups() {
        primaryPopup.removeAllItems()
        secondaryPopup.removeAllItems()

        for connection in v6Connections {
            let title = displayTitle(for: connection)
            let identifier = connection.identifier

            let primaryItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            primaryItem.representedObject = identifier
            primaryItem.toolTip = identifier
            primaryPopup.menu?.addItem(primaryItem)

            let secondaryItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            secondaryItem.representedObject = identifier
            secondaryItem.toolTip = identifier
            secondaryPopup.menu?.addItem(secondaryItem)
        }
    }

    private func selectPopup(_ popup: NSPopUpButton, identifier: String) {
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

    private func refreshUI() {
        let hasAtLeastTwo = v6Connections.count >= 2

        syncEnabledCheckbox.state = Preferences.standard.syncEnabled ? .on : .off
        wipeSecondaryCheckbox.state = Preferences.standard.syncWipeSecondaryBeforeSync ? .on : .off

        populatePopups()

        intervalField.stringValue = "\(Preferences.standard.syncIntervalMinutes)"

        if !Preferences.standard.syncPrimaryIdentifier.isEmpty {
            selectPopup(primaryPopup, identifier: Preferences.standard.syncPrimaryIdentifier)
        }
        if !Preferences.standard.syncSecondaryIdentifier.isEmpty {
            selectPopup(secondaryPopup, identifier: Preferences.standard.syncSecondaryIdentifier)
        }

        if !hasAtLeastTwo {
            syncEnabledCheckbox.isEnabled = false
            primaryPopup.isEnabled = false
            secondaryPopup.isEnabled = false
            intervalField.isEnabled = false
            syncNowButton.isEnabled = false
            statusLabel.stringValue = "Sync requires two Pi-hole v6 connections."
            updateStatus()
            return
        }

        syncEnabledCheckbox.isEnabled = true
        let syncEnabled = syncEnabledCheckbox.state == .on
        primaryPopup.isEnabled = syncEnabled
        secondaryPopup.isEnabled = syncEnabled
        intervalField.isEnabled = syncEnabled
        wipeSecondaryCheckbox.isEnabled = syncEnabled

        if !syncEnabled {
            syncNowButton.isEnabled = false
            statusLabel.stringValue = "Enable Sync to configure Primary/Secondary."
            updateStatus()
            return
        }

        validateSelection()

        let primary = selectedIdentifier(from: primaryPopup)
        let secondary = selectedIdentifier(from: secondaryPopup)
        let selectionValid = !primary.isEmpty && !secondary.isEmpty && primary != secondary
        syncNowButton.isEnabled = selectionValid

        updateStatus()
    }

    private func validateSelection() {
        let primary = selectedIdentifier(from: primaryPopup)
        let secondary = selectedIdentifier(from: secondaryPopup)

        if !primary.isEmpty, primary == secondary, secondaryPopup.numberOfItems > 1 {
            for item in secondaryPopup.itemArray {
                guard let represented = item.representedObject as? String else { continue }
                if represented != primary {
                secondaryPopup.select(item)
                break
                }
            }
            Preferences.standard.set(syncSecondaryIdentifier: selectedIdentifier(from: secondaryPopup))
        }
    }

    private func updateStatus() {
        if let last = Preferences.standard.syncLastRunAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            let status = Preferences.standard.syncLastStatus
            let message = Preferences.standard.syncLastMessage
            statusLabel.stringValue = "Last sync: \(formatter.string(from: last)) \(status.isEmpty ? "" : "– \(status)") \(message)"
        } else {
            statusLabel.stringValue = "No sync run yet."
        }
    }

    @objc private func handleSyncProgress(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        guard let message = userInfo[SyncProgress.messageKey] as? String else { return }
        appendLog(message)
        statusLabel.stringValue = message
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

        let primary = selectedIdentifier(from: primaryPopup)
        let secondary = selectedIdentifier(from: secondaryPopup)
        Preferences.standard.set(syncPrimaryIdentifier: primary)
        Preferences.standard.set(syncSecondaryIdentifier: secondary)

        if let minutes = Int(intervalField.stringValue), minutes >= 5 {
            Preferences.standard.set(syncIntervalMinutes: minutes)
        } else {
            intervalField.stringValue = "\(Preferences.standard.syncIntervalMinutes)"
        }

        delegate?.syncSettingsUpdated()
    }

    // MARK: - Actions

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

    @objc private func intervalChanged() {
        persistSelections()
        refreshUI()
    }

    @objc private func wipeSecondaryChanged() {
        let wantsEnabled = wipeSecondaryCheckbox.state == .on
        if wantsEnabled {
            confirmEnableWipe()
            return
        }

        persistSelections()
        refreshUI()
    }

    private func confirmEnableWipe() {
        guard let window = view.window else {
            persistSelections()
            refreshUI()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Enable destructive pre-clean?"
        alert.informativeText = "Before each sync, PiBar will attempt to delete all adlists on the Secondary Pi-hole (or disable them if deletion isn’t supported), then re-apply adlists from the Primary. This can temporarily reduce blocking on the Secondary until gravity updates."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.persistSelections()
            } else {
                self.wipeSecondaryCheckbox.state = .off
                self.persistSelections()
            }
            self.refreshUI()
        }
    }

    @objc private func syncNowPressed() {
        persistSelections()
        clearLog()
        appendLog("Sync Now: requested")
        delegate?.syncNowRequestedFromSettings()
        refreshUI()
    }

    @objc private func closePressed() {
        dismiss(self)
    }
}
