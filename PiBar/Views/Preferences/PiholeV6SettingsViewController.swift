//
//  PiholeV6SettingsViewController.swift
//  PiBar
//
//  Created by Brad Root on 3/16/25.
//  Copyright © 2025 Brad Root. All rights reserved.
//

import Cocoa

protocol PiholeV6SettingsViewControllerDelegate: AnyObject {
    func savePiholeV3Connection(_ connection: PiholeConnectionV3, at index: Int)
}

class PiholeV6SettingsViewController: NSViewController {
    var connection: PiholeConnectionV3?
    var currentIndex: Int = -1
    weak var delegate: PiholeV6SettingsViewControllerDelegate?

    var passwordProtected: Bool = true
    var validSidToken: String = ""

    // MARK: - Outlets

    @IBOutlet var hostnameTextField: NSTextField!
    @IBOutlet var portTextField: NSTextField!
    @IBOutlet var useSSLCheckbox: NSButton!

    @IBOutlet var adminURLTextField: NSTextField!


    @IBOutlet weak var totpTextField: NSTextField!
    @IBOutlet weak var passwordTextField: NSSecureTextField!
    @IBOutlet var testConnectionLabel: NSTextField!
    @IBOutlet var saveAndCloseButton: NSButton!
    @IBOutlet var closeButton: NSButton!

    // MARK: - Actions

    @IBAction func textFieldDidChangeAction(_: NSTextField) {
        updateAdminURLPlaceholder()
        saveAndCloseButton.isEnabled = false
    }

    @IBAction func useSSLCheckboxAction(_: NSButton) {
        sslFailSafe()
        updateAdminURLPlaceholder()
        saveAndCloseButton.isEnabled = false
    }

    @IBAction func authenticateRequestAction(_ sender: NSButton) {
        let password = passwordTextField.stringValue
        let totp = Int(totpTextField.stringValue)
        Log.debug("Authenticating connection...")

        testConnectionLabel.stringValue = "Authenticating..."
        saveAndCloseButton.isEnabled = false

        let connection = PiholeConnectionV3(
            hostname: hostnameTextField.stringValue,
            port: Int(portTextField.stringValue) ?? 80,
            useSSL: useSSLCheckbox.state == .on ? true : false,
            token: "",
            passwordProtected: passwordProtected,
            adminPanelURL: "",
            isV6: true
        )

        let api = Pihole6API(connection: connection)
        
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await api.checkPassword(password: password, totp: totp)
                await MainActor.run {
                    if result.session.valid, let token = result.session.sid {
                        self.validSidToken = token
                        self.passwordProtected = true
                        self.testConnectionLabel.stringValue = "Authenticated!"
                        self.saveAndCloseButton.isEnabled = true
                    } else if result.session.valid {
                        self.validSidToken = ""
                        self.passwordProtected = false
                        self.testConnectionLabel.stringValue = "Authenticated!"
                        self.saveAndCloseButton.isEnabled = true
                    } else if result.session.totp, totp == nil {
                        self.validSidToken = ""
                        self.passwordProtected = true
                        self.testConnectionLabel.stringValue = "TOTP required"
                        self.saveAndCloseButton.isEnabled = false
                    } else {
                        self.validSidToken = ""
                        self.passwordProtected = true
                        self.testConnectionLabel.stringValue = result.session.message ?? "Invalid credentials"
                        self.saveAndCloseButton.isEnabled = false
                    }
                }
            } catch {
                Log.error(error)
                await MainActor.run {
                    self.validSidToken = ""
                    self.testConnectionLabel.stringValue = self.userFacingErrorMessage(for: error)
                    self.saveAndCloseButton.isEnabled = false
                }
            }
        }
        
    }
    
    @IBAction func testConnectionButtonAction(_: NSButton) {
        testConnection()
    }

    @IBAction func saveAndCloseButtonAction(_: NSButton) {
        var adminPanelURL = adminURLTextField.stringValue
        if adminPanelURL.isEmpty {
            adminPanelURL = PiholeConnectionV3.generateAdminPanelURL(
                hostname: hostnameTextField.stringValue,
                port: Int(portTextField.stringValue) ?? 80,
                useSSL: useSSLCheckbox.state == .on ? true : false
            )
        }
        delegate?.savePiholeV3Connection(PiholeConnectionV3(
            hostname: hostnameTextField.stringValue,
            port: Int(portTextField.stringValue) ?? 80,
            useSSL: useSSLCheckbox.state == .on ? true : false,
            token: self.validSidToken,
            passwordProtected: passwordProtected,
            adminPanelURL: adminPanelURL,
            isV6: true
        ), at: currentIndex)
        dismiss(self)
    }

    // MARK: - View Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        adminURLTextField.toolTip = "Only fill this in if you have a custom Admin panel URL you'd like to use instead of the default shown here."
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        loadPiholeConnection()
    }

    func loadPiholeConnection() {
        Log.debug("Loading Pi-hole at index \(currentIndex)")
        if let connection = connection {
            hostnameTextField.stringValue = connection.hostname
            portTextField.stringValue = "\(connection.port)"
            useSSLCheckbox.state = connection.useSSL ? .on : .off
            passwordProtected = connection.passwordProtected
            validSidToken = connection.token
//            apiTokenTextField.stringValue = connection.token
            adminURLTextField.stringValue = connection.adminPanelURL
        } else {
            hostnameTextField.stringValue = "pi.hole"
            portTextField.stringValue = "80"
            useSSLCheckbox.state = .off
//            apiTokenTextField.stringValue = ""
            adminURLTextField.stringValue = ""
            passwordProtected = true
            validSidToken = ""
            adminURLTextField.placeholderString = PiholeConnectionV3.generateAdminPanelURL(
                hostname: "pi.hole",
                port: 80,
                useSSL: false
            )
        }
        testConnectionLabel.stringValue = ""
        saveAndCloseButton.isEnabled = false
    }

    // MARK: - Functions

    fileprivate func sslFailSafe() {
        let useSSL = useSSLCheckbox.state == .on ? true : false

        var port = portTextField.stringValue
        if useSSL, port == "80" {
            port = "443"
        } else if !useSSL, port == "443" {
            port = "80"
        }
        portTextField.stringValue = port
    }

    private func updateAdminURLPlaceholder() {
        let adminURLString = PiholeConnectionV3.generateAdminPanelURL(
            hostname: hostnameTextField.stringValue,
            port: Int(portTextField.stringValue) ?? 80,
            useSSL: useSSLCheckbox.state == .on ? true : false
        )
        adminURLTextField.placeholderString = "\(adminURLString)"
    }

    func testConnection() {
        Log.debug("Testing connection...")

        testConnectionLabel.stringValue = "Testing... Please wait..."
        saveAndCloseButton.isEnabled = false

        let connection = PiholeConnectionV3(
            hostname: hostnameTextField.stringValue,
            port: Int(portTextField.stringValue) ?? 80,
            useSSL: useSSLCheckbox.state == .on ? true : false,
            token: validSidToken,
            passwordProtected: passwordProtected,
            adminPanelURL: "",
            isV6: true
        )

        let api = Pihole6API(connection: connection)

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await api.fetchSummary()
                await MainActor.run {
                    if self.validSidToken.isEmpty {
                        self.passwordProtected = false
                    }
                    self.testConnectionLabel.stringValue = "Success"
                    self.saveAndCloseButton.isEnabled = true
                }
            } catch {
                Log.error(error)
                await MainActor.run {
                    if self.isAuthFailure(error) {
                        self.testConnectionLabel.stringValue = "Authentication required"
                    } else {
                        self.testConnectionLabel.stringValue = self.userFacingErrorMessage(for: error)
                    }
                    self.saveAndCloseButton.isEnabled = false
                }
            }
        }
    }

    private func isAuthFailure(_ error: Error) -> Bool {
        if let apiError = error as? APIError {
            switch apiError {
            case .unauthorized, .forbidden:
                return true
            default:
                break
            }
        }
        guard let statusCode = pihole6HTTPStatusCode(from: error) else { return false }
        return statusCode == 401 || statusCode == 403
    }

    private func pihole6HTTPStatusCode(from error: Error) -> Int? {
        var currentError: Error = error
        while let apiError = currentError as? APIError, case let .requestFailed(underlying) = apiError {
            currentError = underlying
        }
        if let apiError = currentError as? APIError, case let .invalidResponse(statusCode, _) = apiError {
            return statusCode
        }
        return nil
    }

    private func userFacingErrorMessage(for error: Error) -> String {
        var currentError: Error = error
        while let apiError = currentError as? APIError, case let .requestFailed(underlying) = apiError {
            currentError = underlying
        }
        if let apiError = currentError as? APIError {
            switch apiError {
            case .requestTimedOut:
                return "Request timed out"
            case .unreachableHost:
                return "Unable to Connect"
            case .notConnectedToInternet:
                return "No internet connection"
            case .unauthorized, .forbidden:
                return "Authentication required"
            case .decodingFailed:
                return "Unexpected response"
            default:
                break
            }
        }
        if let urlError = currentError as? URLError {
            switch urlError.code {
            case .timedOut:
                return "Request timed out"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Unable to Connect"
            case .notConnectedToInternet:
                return "No internet connection"
            default:
                return "Network error"
            }
        }
        return "Error"
    }
}
