//
//  PiholeAPI.swift
//  PiBar
//
//  Created by Brad Root on 5/17/20.
//  Copyright © 2020 Brad Root. All rights reserved.
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Cocoa

class PiholeAPI: NSObject {
    let connection: PiholeConnectionV3

    var identifier: String {
        return connection.identifier
    }

    private let path: String = "/admin/api.php"
    private let requestTimeout: TimeInterval = 5

    private enum Endpoints {
        static let summary = PiholeAPIEndpoint(queryParameter: "summaryRaw", authorizationRequired: true)
        static let overTimeData10mins = PiholeAPIEndpoint(queryParameter: "overTimeData10mins", authorizationRequired: true)
        static let topItems = PiholeAPIEndpoint(queryParameter: "topItems", authorizationRequired: true)
        static let topClients = PiholeAPIEndpoint(queryParameter: "topClients", authorizationRequired: true)
        static let enable = PiholeAPIEndpoint(queryParameter: "enable", authorizationRequired: true)
        static let disable = PiholeAPIEndpoint(queryParameter: "disable", authorizationRequired: true)
        static let recentBlocked = PiholeAPIEndpoint(queryParameter: "recentBlocked", authorizationRequired: true)
    }

    override init() {
        connection = PiholeConnectionV3(
            hostname: "pi.hole",
            port: 80,
            useSSL: false,
            token: "",
            passwordProtected: true,
            adminPanelURL: "http://pi.hole/admin/",
            isV6: false
        )
        super.init()
    }

    init(connection: PiholeConnectionV3) {
        self.connection = connection
        super.init()
    }

    private func makeURL(for endpoint: PiholeAPIEndpoint, argument: String?) -> URL? {
        var components = URLComponents()
        components.scheme = connection.useSSL ? "https" : "http"
        components.host = connection.hostname
        components.port = connection.port
        components.path = path

        var items: [URLQueryItem] = []
        if endpoint.authorizationRequired {
            items.append(URLQueryItem(name: "auth", value: connection.token))
        }
        items.append(URLQueryItem(name: endpoint.queryParameter, value: argument))
        components.queryItems = items

        return components.url
    }

    private func get(_ endpoint: PiholeAPIEndpoint, argument: String? = nil, completion: @escaping (String?) -> Void) {
        guard let builtURL = makeURL(for: endpoint, argument: argument) else { return completion(nil) }

        var urlRequest = URLRequest(url: builtURL)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = requestTimeout
        let session = URLSession(configuration: .default)
        let dataTask = session.dataTask(with: urlRequest) { data, response, error in
            if error != nil {
                return completion(nil)
            }
            if let response = response as? HTTPURLResponse {
                if 200 ..< 300 ~= response.statusCode {
                    if let data = data, let string = String(data: data, encoding: .utf8) {
                        completion(string)
                    } else {
                        completion(nil)
                    }
                } else {
                    completion(nil)
                }
            } else {
                completion(nil)
            }
        }
        dataTask.resume()
    }

    private func decodeJSON<T>(_ string: String) -> T? where T: Decodable {
        do {
            let jsonDecoder = JSONDecoder()
            jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
            let jsonData = string.data(using: .utf8)!
            let object = try jsonDecoder.decode(T.self, from: jsonData)
            return object
        } catch {
            return nil
        }
    }

    // MARK: - URLs

    var admin: URL {
        var components = URLComponents()
        components.scheme = connection.useSSL ? "https" : "http"
        components.host = connection.hostname
        components.port = connection.port
        components.path = "/admin"
        return components.url!
    }

    // MARK: - Testing

    func testConnection(completion: @escaping (PiholeConnectionTestResult) -> Void) {
        fetchTopItems { string in
            DispatchQueue.main.async {
                if let contents = string {
                    if contents == "[]" {
                        completion(.failureInvalidToken)
                    } else {
                        completion(.success)
                    }
                } else {
                    completion(.failure)
                }
            }
        }
    }

    // MARK: - Endpoints

    func fetchSummary(completion: @escaping (PiholeAPISummary?) -> Void) {
        DispatchQueue.global(qos: .background).async {
            self.get(Endpoints.summary) { string in
                guard let jsonString = string,
                    let summary: PiholeAPISummary = self.decodeJSON(jsonString) else { return completion(nil) }
                completion(summary)
            }
        }
    }

    func fetchTopItems(completion: @escaping (String?) -> Void) {
        // Only using this endpoint to verify the API token
        // So we don't actually do anything with the output yet
        DispatchQueue.global(qos: .background).async {
            self.get(Endpoints.topItems) { string in
                completion(string)
            }
        }
    }

    func disable(seconds: Int? = nil, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .background).async {
            var secondsString: String?
            if let seconds = seconds {
                secondsString = String(seconds)
            }
            self.get(Endpoints.disable, argument: secondsString) { string in
                guard let jsonString = string,
                    let _: PiholeAPIStatus = self.decodeJSON(jsonString) else { return completion(false) }
                completion(true)
            }
        }
    }

    func enable(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .background).async {
            self.get(Endpoints.enable) { string in
                guard let jsonString = string,
                    let _: PiholeAPIStatus = self.decodeJSON(jsonString) else { return completion(false) }
                completion(true)
            }
        }
    }
}
