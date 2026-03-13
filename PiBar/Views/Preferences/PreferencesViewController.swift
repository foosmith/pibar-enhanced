//
//  PreferencesViewController.swift
//  PiBar
//
//  Created by Brad Root on 5/17/20.
//  Copyright © 2020 Brad Root. All rights reserved.
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Cocoa
import LaunchAtLogin


protocol PreferencesDelegate: AnyObject {
    func updatedPreferences()
    func updatedConnections()
    func syncNowRequested()
}

class PreferencesViewController: NSViewController {
    weak var delegate: PreferencesDelegate?
    private let preferredWindowSize = NSSize(width: 760, height: 470)

    lazy var piholeSheetController: PiholeSettingsViewController? = {
        guard let controller = self.storyboard!.instantiateController(
            withIdentifier: "piHoleDialog"
        ) as? PiholeSettingsViewController else {
            return nil
        }
        return controller
    }()
    
    lazy var piholeV6SheetController: PiholeV6SettingsViewController? = {
        guard let controller = self.storyboard!.instantiateController(
            withIdentifier: "piHoleDialogV6"
        ) as? PiholeV6SettingsViewController else {
            return nil
        }
        return controller
    }()

    private var syncSettingsController: SyncSettingsViewController?
    private var syncSettingsButton: NSButton?
    private var syncSummaryLabel: NSTextField?
    private var connectionsHelperLabel: NSTextField?
    private var notificationsCheckbox: NSButton?
    private weak var pollingRateLabel: NSTextField?

    // MARK: - Outlets

    @IBOutlet var tableView: NSTableView!

    @IBOutlet var showBlockedCheckbox: NSButton!
    @IBOutlet var showQueriesCheckbox: NSButton!
    @IBOutlet var showPercentageCheckbox: NSButton!

    @IBOutlet var showLabelsCheckbox: NSButton!
    @IBOutlet var verboseLabelsCheckbox: NSButton!

    @IBOutlet var shortcutEnabledCheckbox: NSButton!
    @IBOutlet var launchAtLogincheckbox: NSButton!
    @IBOutlet var pollingRateTextField: NSTextField!

    @IBOutlet var editButton: NSButton!
    @IBOutlet var removeButton: NSButton!

    // MARK: - Actions

    @IBAction func addButtonActiom(_: NSButton) {
        let alert = NSAlert()
        alert.messageText = "Pi-hole Version"
        alert.informativeText = "What version of Pi-hole would you like to add?"
        alert.alertStyle = .warning
        
        // Adding buttons
        alert.addButton(withTitle: "Pi-hole v6+") // Index 0
        alert.addButton(withTitle: "Pi-hole v5 or earlier") // Index 1
        alert.addButton(withTitle: "Cancel")   // Index 2

        // Display alert and handle response
        let response = alert.runModal()
        
        switch response {
        case .alertFirstButtonReturn:
            newPihole()
        case .alertSecondButtonReturn:
            legacyVersion()
        case .alertThirdButtonReturn:
            handleCancel()
        default:
            break
        }
    }
    
    func newPihole() {
        guard let controller = piholeV6SheetController else { return }
        controller.delegate = self
        controller.connection = nil
        controller.currentIndex = -1
        presentAsSheet(controller)
    }
    
    func legacyVersion() {
        guard let controller = piholeSheetController else { return }
        controller.delegate = self
        controller.connection = nil
        controller.currentIndex = -1
        presentAsSheet(controller)
    }
    
    func handleCancel() {
        print("Cancel selected")
        // Handle cancellation if needed
    }

    @IBAction func editButtonAction(_: NSButton) {
        if tableView.selectedRow >= 0 {
            let pihole = Preferences.standard.piholes[tableView.selectedRow]
            if pihole.isV6 {
                guard let controller = piholeV6SheetController else { return }
                controller.delegate = self
                controller.connection = pihole
                controller.currentIndex = tableView.selectedRow
                presentAsSheet(controller)
            } else {
                guard let controller = piholeSheetController else { return }
                controller.delegate = self
                controller.connection = pihole
                controller.currentIndex = tableView.selectedRow
                presentAsSheet(controller)
            }
        }
    }

    @IBAction func removeButtonAction(_: NSButton) {
        var piholes = Preferences.standard.piholes
        piholes.remove(at: tableView.selectedRow)
        tableView.removeRows(at: tableView.selectedRowIndexes, withAnimation: .slideUp)
        Preferences.standard.set(piholes: piholes)
        if piholes.isEmpty {
            removeButton.isEnabled = false
            editButton.isEnabled = false
        }
        delegate?.updatedConnections()
    }

    @IBAction func checkboxAction(_: NSButtonCell) {
        saveSettings()
    }
    
    @IBAction func launchAtLoginAction(_ sender: NSButton) {
        
    }
    
    @IBAction func pollingRateTextFieldAction(_: NSTextField) {
        saveSettings()
    }

    @IBAction func saveAndCloseButtonAction(_: NSButton) {
        saveSettings()
        view.window?.close()
    }

    // MARK: - View Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        updateUI()

        shortcutEnabledCheckbox.toolTip = "This shortcut allows you to easily enable and disable your Pi-hole(s)"
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.doubleAction = #selector(handleTableDoubleClick(_:))
        tableView.target = self
        editButton.title = "Edit Selected"
        editButton.toolTip = "Edit the selected Pi-hole connection"
        removeButton.toolTip = "Remove the selected Pi-hole connection"
        pollingRateTextField.toolTip = "Polling rate cannot be less than 3 seconds"
        installSyncSettingsButton()
        installNotificationsCheckbox()
        installConnectionsHelperLabel()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if let window = view.window {
            window.setContentSize(preferredWindowSize)
            window.minSize = preferredWindowSize
        }
    }

    func updateUI() {
        Log.debug("Updating Preferences UI")

        showBlockedCheckbox.state = Preferences.standard.showBlocked ? .on : .off
        showQueriesCheckbox.state = Preferences.standard.showQueries ? .on : .off
        showPercentageCheckbox.state = Preferences.standard.showPercentage ? .on : .off

        showLabelsCheckbox.state = Preferences.standard.showLabels ? .on : .off
        verboseLabelsCheckbox.state = Preferences.standard.verboseLabels ? .on : .off

        if !Preferences.standard.showTitle {
            showLabelsCheckbox.isEnabled = false
            verboseLabelsCheckbox.isEnabled = false
        } else {
            showLabelsCheckbox.isEnabled = true
            verboseLabelsCheckbox.isEnabled = showLabelsCheckbox.state == .on ? true : false
        }
        
        launchAtLogincheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
        notificationsCheckbox?.state = Preferences.standard.notificationsEnabled ? .on : .off
        syncSummaryLabel?.stringValue = syncSummaryText()

        pollingRateTextField.stringValue = "\(Preferences.standard.pollingRate)"
    }

    // MARK: - Functions

    func saveSettings() {
        Preferences.standard.set(showBlocked: showBlockedCheckbox.state == .on ? true : false)
        Preferences.standard.set(showQueries: showQueriesCheckbox.state == .on ? true : false)
        Preferences.standard.set(showPercentage: showPercentageCheckbox.state == .on ? true : false)

        if showLabelsCheckbox.state == .off {
            verboseLabelsCheckbox.state = .off
        }

        Preferences.standard.set(showLabels: showLabelsCheckbox.state == .on ? true : false)
        Preferences.standard.set(verboseLabels: verboseLabelsCheckbox.state == .on ? true : false)

        Preferences.standard.set(shortcutEnabled: shortcutEnabledCheckbox.state == .on ? true : false)
        Preferences.standard.set(notificationsEnabled: notificationsCheckbox?.state == .on ? true : false)
        
        if launchAtLogincheckbox.state == .on {
            LaunchAtLogin.isEnabled = true
        } else {
            LaunchAtLogin.isEnabled = false
        }


        let input = pollingRateTextField.stringValue
        if let intValue = Int(input), intValue >= 3 {
            Preferences.standard.set(pollingRate: intValue)
        } else {
            pollingRateTextField.stringValue = "\(Preferences.standard.pollingRate)"
        }

        delegate?.updatedPreferences()

        updateUI()
    }

    private func installNotificationsCheckbox() {
        guard notificationsCheckbox == nil else { return }
        guard let container = shortcutEnabledCheckbox.superview else { return }
        guard let pollingRateLabel = findLabel(withText: "Polling Rate", in: container) else { return }

        let checkbox = NSButton(checkboxWithTitle: "Enable Notifications", target: self, action: #selector(notificationCheckboxChanged(_:)))
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        checkbox.toolTip = "Show macOS notifications for status changes and quick actions"
        container.addSubview(checkbox)

        if let existingConstraint = container.constraints.first(where: {
            ($0.firstItem as? NSTextField) == pollingRateLabel &&
            $0.firstAttribute == .top &&
            ($0.secondItem as? NSButton) == launchAtLogincheckbox
        }) {
            existingConstraint.isActive = false
        }

        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: launchAtLogincheckbox.leadingAnchor),
            checkbox.topAnchor.constraint(equalTo: launchAtLogincheckbox.bottomAnchor, constant: 8),
            pollingRateLabel.topAnchor.constraint(equalTo: checkbox.bottomAnchor, constant: 12),
        ])

        notificationsCheckbox = checkbox
        self.pollingRateLabel = pollingRateLabel
        checkbox.state = Preferences.standard.notificationsEnabled ? .on : .off
    }

    @objc private func notificationCheckboxChanged(_: NSButton) {
        saveSettings()
    }

    @objc private func handleTableDoubleClick(_: Any?) {
        guard tableView.clickedRow >= 0 || tableView.selectedRow >= 0 else { return }
        editButtonAction(editButton)
    }

    private func installSyncSettingsButton() {
        if syncSettingsButton != nil || syncSummaryLabel != nil {
            return
        }

        guard let saveButton = findSaveAndCloseButton(in: view),
              let footer = saveButton.superview else {
            Log.debug("Sync button: could not find Save & Close button.")
            return
        }

        let button = NSButton(title: "Sync Settings…", target: self, action: #selector(openSyncSettings))
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        button.toolTip = "Configure Primary → Secondary sync and review recent sync activity"

        let summaryLabel = NSTextField(labelWithString: "")
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.maximumNumberOfLines = 2

        footer.addSubview(button)
        footer.addSubview(summaryLabel)

        NSLayoutConstraint.activate([
            summaryLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 20),
            summaryLabel.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
            button.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            button.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
        ])

        syncSettingsButton = button
        syncSummaryLabel = summaryLabel
        summaryLabel.stringValue = syncSummaryText()
    }

    private func installConnectionsHelperLabel() {
        guard connectionsHelperLabel == nil,
              let container = tableView.enclosingScrollView?.superview,
              let scrollView = tableView.enclosingScrollView,
              let addButton = container.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.action == #selector(addButtonActiom(_:)) }) else { return }

        let label = NSTextField(labelWithString: "Tip: double-click a Pi-hole to edit it, or use Add to create new v5/v6 connections.")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 10),
        ])

        container.constraints
            .filter {
                $0.firstAttribute == .top &&
                ($0.secondItem as? NSScrollView) == scrollView &&
                (($0.firstItem as? NSButton) == addButton ||
                 ($0.firstItem as? NSButton) == editButton ||
                 ($0.firstItem as? NSButton) == removeButton)
            }
            .forEach { $0.isActive = false }

        NSLayoutConstraint.activate([
            addButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            editButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            removeButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
        ])

        connectionsHelperLabel = label
    }

    private func findSaveAndCloseButton(in root: NSView) -> NSButton? {
        for subview in root.subviews {
            if let button = subview as? NSButton,
               button.title == "Save & Close",
               button.action == #selector(saveAndCloseButtonAction(_:))
            {
                return button
            }
            if let found = findSaveAndCloseButton(in: subview) {
                return found
            }
        }
        return nil
    }

    private func findLabel(withText text: String, in root: NSView) -> NSTextField? {
        for subview in root.subviews {
            if let textField = subview as? NSTextField, textField.stringValue == text {
                return textField
            }
            if let found = findLabel(withText: text, in: subview) {
                return found
            }
        }
        return nil
    }

    @objc private func openSyncSettings() {
        if syncSettingsController == nil {
            let controller = SyncSettingsViewController()
            controller.delegate = self
            syncSettingsController = controller
        }

        if let controller = syncSettingsController {
            presentAsSheet(controller)
        }
    }

    private func syncSummaryText() -> String {
        let v6Connections = Preferences.standard.piholes.filter(\.isV6)
        guard v6Connections.count >= 2 else {
            let needed = max(0, 2 - v6Connections.count)
            return needed == 0 ? "Sync available" : "Sync needs \(needed) more Pi-hole v6 connection(s)"
        }

        guard Preferences.standard.syncEnabled else {
            return "Sync is off"
        }

        let primary = Preferences.standard.syncPrimaryIdentifier
        let secondary = Preferences.standard.syncSecondaryIdentifier

        guard !primary.isEmpty, !secondary.isEmpty else {
            return "Sync needs a primary and secondary"
        }

        guard primary != secondary else {
            return "Sync selection needs two different Pi-holes"
        }

        let interval = Preferences.standard.syncIntervalMinutes
        if Preferences.standard.syncDryRunEnabled {
            return "Sync ready every \(interval) min (dry run)"
        }
        return "Sync ready every \(interval) min"
    }
}

extension PreferencesViewController: SyncSettingsViewControllerDelegate {
    func syncSettingsUpdated() {
        delegate?.updatedPreferences()
    }

    func syncNowRequestedFromSettings() {
        delegate?.syncNowRequested()
    }
}

extension PreferencesViewController: PiholeSettingsViewControllerDelegate {
    func savePiholeConnection(_ connection: PiholeConnectionV3, at index: Int) {
        var piholes = Preferences.standard.piholes
        if index == -1 {
            piholes.append(connection)
            Preferences.standard.set(piholes: piholes)
            let newRowIndexSet = IndexSet(integer: piholes.count - 1)
            tableView.insertRows(at: newRowIndexSet, withAnimation: .slideDown)
            tableView.selectRowIndexes(newRowIndexSet, byExtendingSelection: false)
        } else {
            piholes[index] = connection
            Preferences.standard.set(piholes: piholes)
            tableView.reloadData()
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        delegate?.updatedConnections()
    }
}

extension PreferencesViewController: PiholeV6SettingsViewControllerDelegate {
    func savePiholeV3Connection(_ connection: PiholeConnectionV3, at index: Int) {
        var piholes = Preferences.standard.piholes
        if index == -1 {
            piholes.append(connection)
            Preferences.standard.set(piholes: piholes)
            let newRowIndexSet = IndexSet(integer: piholes.count - 1)
            tableView.insertRows(at: newRowIndexSet, withAnimation: .slideDown)
            tableView.selectRowIndexes(newRowIndexSet, byExtendingSelection: false)
        } else {
            piholes[index] = connection
            Preferences.standard.set(piholes: piholes)
            tableView.reloadData()
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        delegate?.updatedConnections()
    }
}

// MARK: - TableView Data Source

extension PreferencesViewController: NSTableViewDataSource {
    func numberOfRows(in _: NSTableView) -> Int {
        let numberOfRows = Preferences.standard.piholes.count
        if numberOfRows > 0 {
            editButton.isEnabled = true
            removeButton.isEnabled = true
        } else {
            removeButton.isEnabled = false
            editButton.isEnabled = false
        }
        return numberOfRows
    }
}

// MARK: - TableView Delegate

extension PreferencesViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        var text: String = ""
        var cellIdentifier: NSUserInterfaceItemIdentifier = NSUserInterfaceItemIdentifier(rawValue: "")

        let pihole = Preferences.standard.piholes[row]
        if tableColumn == tableView.tableColumns[0] {
            text = pihole.hostname
            cellIdentifier = NSUserInterfaceItemIdentifier(rawValue: "hostnameCell")
        } else if tableColumn == tableView.tableColumns[1] {
            text = "\(pihole.port)"
            cellIdentifier = NSUserInterfaceItemIdentifier(rawValue: "portCell")
        } else if tableColumn == tableView.tableColumns[2] {
            text = pihole.isV6 ? ">=6" : "<6"
            cellIdentifier = NSUserInterfaceItemIdentifier(rawValue: "versionCell")
        }
        if let cell = tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? NSTableCellView {
            cell.textField?.stringValue = text
            return cell
        }
        return nil
    }

    func tableViewSelectionDidChange(_: Notification) {
        editButton.isEnabled = true
        removeButton.isEnabled = true
    }
}
