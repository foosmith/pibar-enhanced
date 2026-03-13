//
//  AboutViewController.swift
//  PiBar
//
//  Created by Brad Root on 5/26/20.
//  Copyright © 2020 Brad Root. All rights reserved.
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Cocoa

class AboutViewController: NSViewController {
    @IBOutlet private weak var appNameLabel: NSTextField!
    @IBOutlet private weak var versionLabel: NSTextField!
    @IBOutlet private weak var repositoryButton: NSButton!
    @IBOutlet private weak var creditsLabel: NSTextField!

    private let repositoryURL = URL(string: "https://github.com/foosmith/pibar-enhanced")!

    @IBAction func aboutURLAction(_: NSButton) {
        NSWorkspace.shared.open(repositoryURL)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        appNameLabel.stringValue = "PiBar Enhanced"
        repositoryButton.title = "github.com/foosmith/pibar-enhanced"
        creditsLabel.stringValue = """
        Maintained by foosmith
        Copyright © 2025 foosmith.
        Pi-hole® is a registered trademark
        of Pi-hole LLC.
        """

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let version, let build, !build.isEmpty {
            versionLabel.stringValue = "Version \(version) (\(build))"
        } else if let version {
            versionLabel.stringValue = "Version \(version)"
        }
    }
}
