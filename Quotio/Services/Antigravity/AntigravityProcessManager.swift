//
//  AntigravityProcessManager.swift
//  Quotio
//
//  Manages Antigravity process lifecycle for account switching.
//  Handles detection, graceful termination, and restart.
//

import Foundation
import AppKit

/// Manages Antigravity process lifecycle
@MainActor
final class AntigravityProcessManager {
    
    // MARK: - Target

    private struct LegacyTarget {
        static let bundleIdentifiers = AntigravityPaths.bundleIdentifiers
        static let helperPrefix = "Antigravity Helper"
        static let appPaths = AntigravityPaths.legacyAppPaths
    }

    // MARK: - Constants

    private static let terminationTimeout: TimeInterval = 20.0
    private static let forceKillTimeout: TimeInterval = 3.0
    
    // MARK: - Singleton
    
    static let shared = AntigravityProcessManager()
    private init() {}
    
    // MARK: - Process Detection
    
    /// Check if Antigravity is currently running
    func isRunning() -> Bool {
        !runningInstances().isEmpty
    }
    
    /// Get running Antigravity application instances
    private func runningInstances() -> [NSRunningApplication] {
        var instances: [NSRunningApplication] = []
        for bundleId in LegacyTarget.bundleIdentifiers {
            instances.append(contentsOf: NSRunningApplication.runningApplications(withBundleIdentifier: bundleId))
        }
        return instances
    }
    
    // MARK: - Process Control
    
    /// Gracefully terminate Antigravity
    /// - Returns: true if successfully terminated, false if force kill was needed
    @discardableResult
    func terminate() async -> Bool {
        let apps = runningInstances()
        guard !apps.isEmpty else { return true }
        
        for app in apps {
            app.terminate()
        }
        
        let gracefullyTerminated = await waitForTermination(timeout: Self.terminationTimeout)
        
        if gracefullyTerminated {
            await killHelperProcesses()
            return true
        }
        
        for app in apps {
            app.forceTerminate()
        }
        
        _ = await waitForTermination(timeout: Self.forceKillTimeout)
        
        await killHelperProcesses()
        
        return false
    }
    
    /// Terminate Antigravity and any helper processes, even if the main app is not running
    @discardableResult
    func terminateAllProcesses() async -> Bool {
        let apps = runningInstances()
        if apps.isEmpty {
            await killHelperProcesses()
            return true
        }
        return await terminate()
    }
    
    // MARK: - Helper Process Cleanup
    
    private func killHelperProcesses() async {
        let prefix = LegacyTarget.helperPrefix
        let helperPatterns = [
            prefix,
            "\(prefix) (GPU)",
            "\(prefix) (Plugin)",
            "\(prefix) (Renderer)"
        ]

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task.detached(priority: .userInitiated) {
                for pattern in helperPatterns {
                    let killall = Process()
                    killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                    killall.arguments = ["-9", pattern, "-t", "2"]
                    killall.standardOutput = FileHandle.nullDevice
                    killall.standardError = FileHandle.nullDevice
                    try? killall.run()
                    killall.waitUntilExit()
                }

                let pkill = Process()
                pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                pkill.arguments = ["-9", "-f", prefix]
                pkill.standardOutput = FileHandle.nullDevice
                pkill.standardError = FileHandle.nullDevice
                try? pkill.run()
                pkill.waitUntilExit()

                continuation.resume()
            }
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    
    /// Wait for all instances to terminate
    private func waitForTermination(timeout: TimeInterval) async -> Bool {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            if Task.isCancelled {
                return false
            }
            if runningInstances().isEmpty {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        return runningInstances().isEmpty
    }
    
    func launch() async throws {
        var appURL: URL?

        for path in LegacyTarget.appPaths where FileManager.default.fileExists(atPath: path) {
            appURL = URL(fileURLWithPath: path)
            break
        }

        if appURL == nil {
            for bundleId in LegacyTarget.bundleIdentifiers {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
                   AntigravityPaths.isAntigravityApp(at: url) {
                    appURL = url
                    break
                }
            }
        }
        
        guard let url = appURL else {
            throw ProcessError.applicationNotFound
        }
        
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        
        try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
    
    // MARK: - Errors
    
    enum ProcessError: LocalizedError {
        case applicationNotFound
        case terminationFailed
        case launchFailed(Error)
        
        var errorDescription: String? {
            switch self {
            case .applicationNotFound:
                return "Antigravity not found. Please ensure it is installed."
            case .terminationFailed:
                return "Failed to terminate Antigravity"
            case .launchFailed(let error):
                return "Failed to launch Antigravity: \(error.localizedDescription)"
            }
        }
    }
}
