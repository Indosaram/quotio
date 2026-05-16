//
//  CompatibilityChecker.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Service for validating proxy is responding before activation.
//

import Foundation

actor CompatibilityChecker {
    
    private let session: URLSession
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Public API
    
    func checkCompatibility(port: UInt16, host: String = "127.0.0.1", managementKey: String) async -> CompatibilityCheckResult {
        let baseURL = "http://\(host):\(port)"
        do {
            let isResponding = try await checkManagementEndpoint(baseURL: baseURL, managementKey: managementKey)
            return isResponding ? .compatible : .proxyNotResponding
        } catch {
            return .connectionError(error.localizedDescription)
        }
    }
    
    func isHealthy(port: UInt16, host: String = "127.0.0.1", managementKey: String) async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/v0/management/debug") else {
            return false
        }
        var request = buildManagementRequest(url: url, managementKey: managementKey)
        request.timeoutInterval = 3
        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return 200...299 ~= httpResponse.statusCode
        } catch {
            return false
        }
    }
    
    func fullCheck(port: UInt16, host: String = "127.0.0.1", managementKey: String) async -> CompatibilityCheckResult {
        guard await isHealthy(port: port, host: host, managementKey: managementKey) else {
            return .proxyNotRunning
        }
        return await checkCompatibility(port: port, host: host, managementKey: managementKey)
    }
    
    // MARK: - Private Helpers
    
    private func buildManagementRequest(url: URL, managementKey: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        if !managementKey.isEmpty {
            request.addValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
    
    private func checkManagementEndpoint(baseURL: String, managementKey: String) async throws -> Bool {
        guard let url = URL(string: "\(baseURL)/v0/management/debug") else {
            throw APIError.invalidURL
        }
        let request = buildManagementRequest(url: url, managementKey: managementKey)
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        return 200...299 ~= httpResponse.statusCode
    }
}

// MARK: - Convenience Extensions

extension CompatibilityCheckResult {
    var shouldProceed: Bool {
        switch self {
        case .compatible:
            return true
        case .proxyNotResponding, .proxyNotRunning, .connectionError:
            return false
        }
    }
}
