//
//  MainMenuController.swift
//  PiBar
//
//  Created by Brad Root on 5/17/20.
//  Copyright © 2020 Brad Root. All rights reserved.
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Cocoa
import HotKey

class MainMenuController: NSObject, NSMenuDelegate, PreferencesDelegate, PiBarManagerDelegate {
    private let toggleHotKey = HotKey(key: .p, modifiers: [.command, .option, .shift])

    private let manager: PiBarManager = PiBarManager()

    private var networkOverview: PiholeNetworkOverview?
    private var hasDeliveredInitialStatusNotification = false

    // MARK: - Internal Views

    private let statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private lazy var preferencesWindowController = NSStoryboard(
        name: "Main",
        bundle: nil
    ).instantiateController(
        withIdentifier: "PreferencesWindowContoller"
    ) as? PreferencesWindowController

    private lazy var aboutWindowController = NSStoryboard(
        name: "Main",
        bundle: nil
    ).instantiateController(
        withIdentifier: "AboutWindowController"
    ) as? NSWindowController

    // MARK: - Outlets

    @IBOutlet var mainMenu: NSMenu!
    @IBOutlet var mainNetworkStatusMenuItem: NSMenuItem!
    @IBOutlet var mainTotalQueriesMenuItem: NSMenuItem!
    @IBOutlet var mainTotalBlockedMenuItem: NSMenuItem!
    @IBOutlet var mainBlocklistMenuItem: NSMenuItem!
    @IBOutlet var disableNetworkMenuItem: NSMenuItem!
    @IBOutlet var enableNetworkMenuItem: NSMenuItem!
    @IBOutlet var webAdminMenuItem: NSMenuItem!


    // MARK: - Sync menu item (programmatically managed)

    private var syncNowMenuItem: NSMenuItem?
    private var syncSeparatorMenuItem: NSMenuItem?

    // MARK: - Sub-menus for Multi-hole Setups

    private var networkStatusMenu = NSMenu()
    private var networkStatusMenuItems: [String: NSMenuItem] = [:]

    private var totalQueriesMenu = NSMenu()
    private var totalQueriesMenuItems: [String: NSMenuItem] = [:]

    private var totalBlockedMenu = NSMenu()
    private var totalBlockedMenuItems: [String: NSMenuItem] = [:]

    private var blocklistMenu = NSMenu()
    private var blocklistMenuItems: [String: NSMenuItem] = [:]

    private var webAdminMenu = NSMenu()
    private var webAdminMenuItems: [String: NSMenuItem] = [:]

    private var topDomainsMenuItem: NSMenuItem?
    private var topDomainsMenu = NSMenu()

    private var topClientsMenuItem: NSMenuItem?
    private var topClientsMenu = NSMenu()

    private var updateGravityMenuItem: NSMenuItem?
    private var quickAllowBlockMenuItem: NSMenuItem?

    // MARK: - Actions

    @IBAction func configureMenuBarAction(_: NSMenuItem) {
        preferencesWindowController?.showWindow(self)
    }

    @IBAction func quitMenuBarAction(_: NSMenuItem) {
        NSApplication.shared.terminate(self)
    }

    @IBAction func disableMenuBarAction(_ sender: NSMenuItem) {
        let seconds = sender.tag > 0 ? sender.tag : nil
        Log.info("Disabling via Menu for \(String(describing: seconds)) seconds")
        manager.disableNetwork(seconds: seconds)
    }

    @IBAction func enableMenuBarAction(_: NSMenuItem) {
        manager.enableNetwork()
    }

    @IBAction func aboutAction(_: NSMenuItem) {
        aboutWindowController?.showWindow(self)
    }

    // MARK: - View Lifecycle

    override init() {
        super.init()
        manager.delegate = self
    }

    override func awakeFromNib() {
        if let statusBarButton = statusBarItem.button {
            statusBarButton.image = NSImage(named: "icon")
            statusBarButton.imagePosition = .imageLeading
            statusBarButton.title = "Initializing"
        }
        statusBarItem.menu = mainMenu
        mainMenu.delegate = self
        installDynamicMenuItems()

        NotificationCenter.default.addObserver(self, selector: #selector(handleSyncBegan),  name: .piBarSyncBegan, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleSyncEnded),  name: .piBarSyncEnded, object: nil)

        enableKeyboardShortcut()

        if let viewController = preferencesWindowController?.contentViewController as? PreferencesViewController {
            viewController.delegate = self
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Keyboard Shortcut

    fileprivate func enableKeyboardShortcut() {
        if Preferences.standard.shortcutEnabled {
            toggleHotKey.isPaused = false
            toggleHotKey.keyDownHandler = {
                Log.debug("Toggling Network from Keyboard Shortcut")
                self.manager.toggleNetwork()
            }
        }
    }

    fileprivate func disableKeyboardShortcut() {
        if !Preferences.standard.shortcutEnabled {
            toggleHotKey.isPaused = true
        }
    }

    // MARK: - Delegate Methods

    internal func updatedConnections() {
        Log.debug("Connections Updated")
        clearSubmenus()
        manager.loadConnections()
        manager.configureSyncFromPreferences()
        DispatchQueue.main.async {
            self.setupWebAdminMenus()
        }
    }

    internal func updateNetwork(_ network: PiholeNetworkOverview) {
        notifyIfNeeded(for: network)
        networkOverview = network
        updateInterface()
        DispatchQueue.main.async {
            self.setupWebAdminMenus()
        }
    }

    // MARK: - Functions

    @objc func launchWebAdmin(sender: NSMenuItem) {
        if sender.title == "Admin Console" {
            guard let piholeIdentifier = networkOverview?.piholes.keys.first else {
                Log.debug("No Pi-holes found.")
                return
            }
            launchWebAdmin(for: piholeIdentifier)
        } else {
            launchWebAdmin(for: sender.title)
        }
    }

    private func launchWebAdmin(for identifier: String) {
        guard let pihole = networkOverview?.piholes[identifier] else {
            Log.debug("Could not find Pi-hole with identifier \(identifier)")
            return
        }
        if let legacyAPI = pihole.api, let adminURL = URL(string: legacyAPI.connection.adminPanelURL) {
            NSWorkspace.shared.open(adminURL)
        } else if let newAPI = pihole.api6, let adminURL = URL(string: newAPI.connection.adminPanelURL) {
            NSWorkspace.shared.open(adminURL)
        }
        
    }

    // MARK: - UI Updates

    internal func updatedPreferences() {
        Log.debug("Preferences Updated")

        updateInterface()

        if Preferences.standard.shortcutEnabled {
            enableKeyboardShortcut()
        } else if !Preferences.standard.shortcutEnabled {
            disableKeyboardShortcut()
        }

        manager.setPollingRate(to: Preferences.standard.pollingRate)
        manager.configureSyncFromPreferences()
    }

    internal func syncNowRequested() {
        Log.info("Sync Now requested")
        manager.syncNow()
    }

    @objc private func syncNowMenuAction() {
        manager.syncNow()
    }

    @objc private func handleSyncBegan() {
        syncNowMenuItem?.title   = "Syncing…"
        syncNowMenuItem?.isEnabled = false
    }

    @objc private func handleSyncEnded() {
        syncNowMenuItem?.title   = "Sync Now"
        syncNowMenuItem?.isEnabled = true
    }

    @objc private func updateGravityMenuAction() {
        manager.updateGravity { [weak self] result in
            self?.handleActionResult(result, successBody: "Gravity update started on \(result.successfulIdentifiers.count) Pi-hole(s).")
        }
    }

    @objc private func quickAllowBlockMenuAction() {
        let alert = NSAlert()
        alert.messageText = "Quick Allow/Block"
        alert.informativeText = "Enter a domain to allow or block across all manageable Pi-hole connections."
        alert.alertStyle = .informational
        alert.addButton(withTitle: QuickDomainAction.allow.buttonTitle)
        alert.addButton(withTitle: QuickDomainAction.block.buttonTitle)
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "example.com"
        alert.accessoryView = field

        let response = alert.runModal()
        let domain = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !domain.isEmpty else { return }

        let action: QuickDomainAction
        switch response {
        case .alertFirstButtonReturn:
            action = .allow
        case .alertSecondButtonReturn:
            action = .block
        default:
            return
        }

        manager.applyQuickDomainAction(action, domain: domain) { [weak self] result in
            self?.handleActionResult(result, successBody: "\(action.pastTenseTitle) \(domain) on \(result.successfulIdentifiers.count) Pi-hole(s).")
        }
    }

    private func updateInterface() {
        Log.debug("Updating Interface")

        DispatchQueue.main.async {
            self.updateMenuBarTitle()
            self.updateStatusButtons()
            self.updateMenuButtons()
            self.updateStatusSubmenus()
            self.updateTopListMenus()
        }
    }

    private func notifyIfNeeded(for updatedNetwork: PiholeNetworkOverview) {
        let previousStatus = networkOverview?.networkStatus
        let currentStatus = updatedNetwork.networkStatus

        guard hasDeliveredInitialStatusNotification else {
            hasDeliveredInitialStatusNotification = true
            return
        }

        guard let previousStatus, previousStatus != .initializing, previousStatus != currentStatus else {
            return
        }

        guard Preferences.standard.notificationsEnabled else {
            return
        }

        AppDelegate.deliverNotification(
            title: "PiBar Status Changed",
            body: "\(previousStatus.rawValue) → \(currentStatus.rawValue)"
        )
    }

    private func setMenuBarTitle(_ title: String) {
        Log.debug("Set Button Title: \(title)")

        if let statusBarButton = statusBarItem.button {
            DispatchQueue.main.async {
                if title.isEmpty {
                    statusBarButton.imagePosition = .imageOnly
                } else {
                    statusBarButton.imagePosition = .imageLeading
                    statusBarButton.title = title
                }
            }
        }
    }

    private func updateMenuBarTitle() {
        guard let networkOverview = networkOverview else { return }
        let currentStatus = networkOverview.networkStatus

        var titleElements: [String] = []

        if currentStatus == .enabled || currentStatus == .partiallyEnabled {
            let showLabels = Preferences.standard.showLabels
            let verboseLabels = Preferences.standard.verboseLabels
            if Preferences.standard.showQueries {
                if showLabels {
                    let label = verboseLabels ? "Queries:" : "Q:"
                    titleElements.append(label)
                }
                titleElements.append(networkOverview.totalQueriesToday.string)
                if Preferences.standard.showBlocked || Preferences.standard.showPercentage, showLabels {
                    titleElements.append("•")
                }
            }
            if Preferences.standard.showBlocked {
                if showLabels {
                    let label = verboseLabels ? "Blocked:" : "B:"
                    titleElements.append(label)
                }
                if Preferences.standard.showQueries, !showLabels {
                    titleElements.append("/")
                }
                titleElements.append(networkOverview.adsBlockedToday.string)
            }

            if Preferences.standard.showPercentage {
                if Preferences.standard.showBlocked || (Preferences.standard.showQueries && !showLabels) {
                    titleElements.append("(\(networkOverview.adsPercentageToday.string))")
                } else {
                    if showLabels {
                        let label = verboseLabels ? "Blocked:" : "B:"
                        titleElements.append(label)
                    }
                    titleElements.append("\(networkOverview.adsPercentageToday.string)")
                }
            }
        } else {
            titleElements = [currentStatus.rawValue]
        }

        // Set title
        let titleString = titleElements.joined(separator: " ")
        setMenuBarTitle(titleString)
    }

    private func updateStatusButtons() {
        guard let networkOverview = networkOverview else { return }
        mainNetworkStatusMenuItem.title = "Status: \(networkOverview.networkStatus.rawValue)"
        mainTotalQueriesMenuItem.title = "Queries: \(networkOverview.totalQueriesToday.string)"
        mainTotalBlockedMenuItem.title = "Blocked: " +
            "\(networkOverview.adsBlockedToday.string) " +
            "(\(networkOverview.adsPercentageToday.string))"
        mainBlocklistMenuItem.title = "Blocklist: \(networkOverview.averageBlocklist.string)"

        updateStatusSubmenus()
    }

    private func updateStatusSubmenus() {
        guard let networkOverview = networkOverview else { return }
        guard let mainMenu = mainNetworkStatusMenuItem.menu else { return }

        let piholes = networkOverview.piholes
        if piholes.count > 1 {
            let piholeIdentifiersAlphabetized: [String] = piholes.keys.sorted()

            for identifier in piholeIdentifiersAlphabetized {
                guard let pihole = piholes[identifier] else { continue }

                // Status Submenu
                if networkStatusMenuItems[identifier] == nil {
                    let menuItem = NSMenuItem(
                        title: "\(identifier): Initializing",
                        action: nil,
                        keyEquivalent: ""
                    )
                    networkStatusMenuItems[identifier] = menuItem
                    networkStatusMenu.addItem(menuItem)
                }

                if !mainNetworkStatusMenuItem.hasSubmenu {
                    mainMenu.setSubmenu(networkStatusMenu, for: mainNetworkStatusMenuItem)
                    mainNetworkStatusMenuItem.isEnabled = true
                }

                if let menuItem = networkStatusMenuItems[identifier] {
                    menuItem.title = "\(identifier): \(pihole.status.rawValue)"
                }

                // Total Queries Submenu
                if totalQueriesMenuItems[identifier] == nil {
                    let menuItem = NSMenuItem(
                        title: "\(identifier): 0",
                        action: nil,
                        keyEquivalent: ""
                    )
                    totalQueriesMenuItems[identifier] = menuItem
                    totalQueriesMenu.addItem(menuItem)
                }

                if !mainTotalQueriesMenuItem.hasSubmenu {
                    mainMenu.setSubmenu(totalQueriesMenu, for: mainTotalQueriesMenuItem)
                    mainTotalQueriesMenuItem.isEnabled = true
                }

                if let menuItem = totalQueriesMenuItems[identifier] {
                    menuItem.title = "\(identifier): \((pihole.summary?.dnsQueriesToday ?? 0).string)"
                }

                // Total Blocked Submenu
                if totalBlockedMenuItems[identifier] == nil {
                    let menuItem = NSMenuItem(
                        title: "\(identifier): 0 (100%)",
                        action: nil,
                        keyEquivalent: ""
                    )
                    totalBlockedMenuItems[identifier] = menuItem
                    totalBlockedMenu.addItem(menuItem)
                }

                if !mainTotalBlockedMenuItem.hasSubmenu {
                    mainMenu.setSubmenu(totalBlockedMenu, for: mainTotalBlockedMenuItem)
                    mainTotalBlockedMenuItem.isEnabled = true
                }

                if let menuItem = totalBlockedMenuItems[identifier] {
                    menuItem.title = "\(identifier): " +
                        "\((pihole.summary?.adsBlockedToday ?? 0).string) " +
                        "(\((pihole.summary?.adsPercentageToday ?? 100.0).string))"
                }

                // Blocklist Submenu
                if blocklistMenuItems[identifier] == nil {
                    let menuItem = NSMenuItem(
                        title: "\(identifier): 0",
                        action: nil,
                        keyEquivalent: ""
                    )
                    blocklistMenuItems[identifier] = menuItem
                    blocklistMenu.addItem(menuItem)
                }

                if !mainBlocklistMenuItem.hasSubmenu {
                    mainMenu.setSubmenu(blocklistMenu, for: mainBlocklistMenuItem)
                    mainBlocklistMenuItem.isEnabled = true
                }

                if let menuItem = blocklistMenuItems[identifier] {
                    menuItem.title = "\(identifier): \((pihole.summary?.domainsBeingBlocked ?? 0).string)"
                }
            }
        }
    }

    private func setupWebAdminMenus() {
        guard let networkOverview = networkOverview else { return }
        guard let mainMenu = mainNetworkStatusMenuItem.menu else { return }
        let piholes = networkOverview.piholes

        if piholes.count > 1 {
            let piholeIdentifiersAlphabetized: [String] = piholes.keys.sorted()

            for identifier in piholeIdentifiersAlphabetized {
                // Web Admin Submenu
                if webAdminMenuItems[identifier] == nil {
                    let menuItem = NSMenuItem(
                        title: identifier,
                        action: #selector(launchWebAdmin(sender:)),
                        keyEquivalent: ""
                    )
                    menuItem.isEnabled = true
                    menuItem.target = self
                    webAdminMenuItems[identifier] = menuItem
                    webAdminMenu.addItem(menuItem)
                }

                if !webAdminMenuItem.hasSubmenu {
                    mainMenu.setSubmenu(webAdminMenu, for: webAdminMenuItem)
                    webAdminMenuItem.isEnabled = true
                }
            }
        } else if piholes.count == 1 {
            webAdminMenuItem.target = self
            webAdminMenuItem.action = #selector(launchWebAdmin(sender:))
            webAdminMenuItem.isEnabled = true
        }
    }

    private func installDynamicMenuItems() {
        installTopListMenuItems()
        installActionMenuItems()
    }

    private func installTopListMenuItems() {
        guard topDomainsMenuItem == nil,
              topClientsMenuItem == nil,
              let blocklistIndex = mainMenu.items.firstIndex(where: { $0 === mainBlocklistMenuItem }) else {
            return
        }

        let domainsItem = NSMenuItem(title: "Top Domains", action: nil, keyEquivalent: "")
        domainsItem.isEnabled = false
        mainMenu.insertItem(domainsItem, at: blocklistIndex + 1)
        topDomainsMenuItem = domainsItem

        let clientsItem = NSMenuItem(title: "Top Clients", action: nil, keyEquivalent: "")
        clientsItem.isEnabled = false
        mainMenu.insertItem(clientsItem, at: blocklistIndex + 2)
        topClientsMenuItem = clientsItem
    }

    private func installActionMenuItems() {
        guard updateGravityMenuItem == nil,
              quickAllowBlockMenuItem == nil,
              let adminIndex = mainMenu.items.firstIndex(where: { $0 === webAdminMenuItem }) else {
            return
        }

        let gravityItem = NSMenuItem(title: "Update Gravity", action: #selector(updateGravityMenuAction), keyEquivalent: "g")
        gravityItem.target = self
        gravityItem.isEnabled = false
        mainMenu.insertItem(gravityItem, at: adminIndex + 1)
        updateGravityMenuItem = gravityItem

        let quickItem = NSMenuItem(title: "Quick Allow/Block…", action: #selector(quickAllowBlockMenuAction), keyEquivalent: "b")
        quickItem.target = self
        quickItem.isEnabled = false
        mainMenu.insertItem(quickItem, at: adminIndex + 2)
        quickAllowBlockMenuItem = quickItem
    }

    private func updateTopListMenus() {
        guard let networkOverview else { return }

        configureTopListMenu(
            item: topDomainsMenuItem,
            menu: topDomainsMenu,
            title: "Top Domains",
            entriesByPihole: networkOverview.piholes
                .sorted { $0.key < $1.key }
                .map { ($0.key, $0.value.topDomains) }
        )

        configureTopListMenu(
            item: topClientsMenuItem,
            menu: topClientsMenu,
            title: "Top Clients",
            entriesByPihole: networkOverview.piholes
                .sorted { $0.key < $1.key }
                .map { ($0.key, $0.value.topClients) }
        )
    }

    private func configureTopListMenu(
        item: NSMenuItem?,
        menu: NSMenu,
        title: String,
        entriesByPihole: [(String, [TopListEntry])]
    ) {
        guard let item, let mainMenu = item.menu else { return }

        menu.removeAllItems()
        let nonEmpty = entriesByPihole.filter { !$0.1.isEmpty }
        item.title = title

        guard !nonEmpty.isEmpty else {
            mainMenu.setSubmenu(nil, for: item)
            item.isEnabled = false
            return
        }

        if nonEmpty.count == 1, let entries = nonEmpty.first?.1 {
            entries.prefix(10).forEach { entry in
                menu.addItem(NSMenuItem(title: "\(entry.name): \(entry.count.string)", action: nil, keyEquivalent: ""))
            }
        } else {
            for (identifier, entries) in nonEmpty {
                let parentItem = NSMenuItem(title: identifier, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: identifier)
                entries.prefix(10).forEach { entry in
                    submenu.addItem(NSMenuItem(title: "\(entry.name): \(entry.count.string)", action: nil, keyEquivalent: ""))
                }
                menu.setSubmenu(submenu, for: parentItem)
                menu.addItem(parentItem)
            }
        }

        mainMenu.setSubmenu(menu, for: item)
        item.isEnabled = true
    }

    private func handleActionResult(_ result: PiBarActionResult, successBody: String) {
        if result.successfulIdentifiers.isEmpty && result.failedIdentifiers.isEmpty {
            let alert = NSAlert()
            alert.messageText = result.actionTitle
            alert.informativeText = "No manageable Pi-hole connections are currently available."
            alert.runModal()
            return
        }

        if !result.successfulIdentifiers.isEmpty {
            if Preferences.standard.notificationsEnabled {
                AppDelegate.deliverNotification(title: result.actionTitle, body: successBody)
            }
        }

        guard !result.failedIdentifiers.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(result.actionTitle) finished with issues"
        alert.informativeText = "Failed on: \(result.failedIdentifiers.joined(separator: ", "))"
        alert.runModal()
    }

    private func clearSubmenus() {
        guard let mainMenu = mainNetworkStatusMenuItem.menu else { return }
        if mainNetworkStatusMenuItem.hasSubmenu {
            mainMenu.setSubmenu(nil, for: mainNetworkStatusMenuItem)
            networkStatusMenu.removeAllItems()
            networkStatusMenuItems.removeAll()
        }

        if mainTotalQueriesMenuItem.hasSubmenu {
            mainMenu.setSubmenu(nil, for: mainTotalQueriesMenuItem)
            totalQueriesMenu.removeAllItems()
            totalQueriesMenuItems.removeAll()
        }

        if mainTotalBlockedMenuItem.hasSubmenu {
            mainMenu.setSubmenu(nil, for: mainTotalBlockedMenuItem)
            totalBlockedMenu.removeAllItems()
            totalBlockedMenuItems.removeAll()
        }

        if mainBlocklistMenuItem.hasSubmenu {
            mainMenu.setSubmenu(nil, for: mainBlocklistMenuItem)
            blocklistMenu.removeAllItems()
            blocklistMenuItems.removeAll()
        }

        if webAdminMenuItem.hasSubmenu {
            mainMenu.setSubmenu(nil, for: webAdminMenuItem)
            webAdminMenu.removeAllItems()
            webAdminMenuItems.removeAll()
        }
        if let topDomainsMenuItem, topDomainsMenuItem.hasSubmenu {
            mainMenu.setSubmenu(nil, for: topDomainsMenuItem)
            topDomainsMenu.removeAllItems()
        }
        if let topClientsMenuItem, topClientsMenuItem.hasSubmenu {
            mainMenu.setSubmenu(nil, for: topClientsMenuItem)
            topClientsMenu.removeAllItems()
        }
        webAdminMenuItem.action = nil
        webAdminMenuItem.isEnabled = false
    }

    private func updateSyncMenuItem() {
        let shouldShow = Preferences.standard.syncEnabled
            && !Preferences.standard.syncPrimaryIdentifier.isEmpty
            && !Preferences.standard.syncSecondaryIdentifier.isEmpty

        if shouldShow {
            if syncNowMenuItem == nil {
                let separator = NSMenuItem.separator()
                let item = NSMenuItem(title: "Sync Now", action: #selector(syncNowMenuAction), keyEquivalent: "")
                item.target = self
                // Insert before the last separator + "Preferences…" pair near the bottom.
                // Find the Preferences item index and insert above it.
                if let prefsIndex = mainMenu.items.firstIndex(where: { $0.action == #selector(configureMenuBarAction(_:)) }) {
                    mainMenu.insertItem(separator, at: prefsIndex)
                    mainMenu.insertItem(item, at: prefsIndex)
                } else {
                    mainMenu.addItem(separator)
                    mainMenu.addItem(item)
                }
                syncSeparatorMenuItem = separator
                syncNowMenuItem = item
            }
        } else {
            if let item = syncNowMenuItem {
                mainMenu.removeItem(item)
                syncNowMenuItem = nil
            }
            if let sep = syncSeparatorMenuItem {
                mainMenu.removeItem(sep)
                syncSeparatorMenuItem = nil
            }
        }
    }

    private func updateMenuButtons() {
        guard let networkOverview = networkOverview else { return }
        let currentStatus = networkOverview.networkStatus

        if !networkOverview.canBeManaged {
            disableNetworkMenuItem.isEnabled = false
            enableNetworkMenuItem.isEnabled = false
        } else if currentStatus == .enabled || currentStatus == .partiallyEnabled {
            enableNetworkMenuItem.isEnabled = false
            enableNetworkMenuItem.isHidden = true
            disableNetworkMenuItem.isEnabled = true
            disableNetworkMenuItem.isHidden = false
        } else if currentStatus == .disabled {
            enableNetworkMenuItem.isEnabled = true
            enableNetworkMenuItem.isHidden = false
            disableNetworkMenuItem.isEnabled = false
            disableNetworkMenuItem.isHidden = true
        } else {
            disableNetworkMenuItem.isEnabled = false
            enableNetworkMenuItem.isEnabled = false
        }

        if networkOverview.piholes.count > 1 {
            disableNetworkMenuItem.title = "Disable Pi-holes"
            enableNetworkMenuItem.title = "Enable Pi-holes"
        } else {
            disableNetworkMenuItem.title = "Disable Pi-hole"
            enableNetworkMenuItem.title = "Enable Pi-hole"
        }

        updateGravityMenuItem?.isEnabled = networkOverview.canBeManaged
        quickAllowBlockMenuItem?.isEnabled = networkOverview.canBeManaged

        updateSyncMenuItem()
    }
}
