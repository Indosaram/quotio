//
//  AntigravityAccountSwitcher.swift
//  Quotio
//
//  Orchestrates the account switching flow for Antigravity IDE.
//  Coordinates database backup, token injection, keychain update, and IDE restart.
//  (Switch and Quota only - no CLI routing mutations)
//

import Foundation



/// Orchestrates Antigravity account switching with proper error handling and rollback
@MainActor
@Observable
final class AntigravityAccountSwitcher {
    
    // MARK: - Singleton
    
    static let shared = AntigravityAccountSwitcher()
    private init() {}
    
    // MARK: - Dependencies
    // Lazy-load database service only when needed (saves memory if Antigravity not installed)
    private var _databaseService: AntigravityDatabaseService?
    private var databaseService: AntigravityDatabaseService {
        if let service = _databaseService {
            return service
        }
        let service = AntigravityDatabaseService()
        _databaseService = service
        return service
    }
    private let processManager = AntigravityProcessManager.shared
    private let quotaFetcher = AntigravityQuotaFetcher()
    private let deviceManager = AntigravityDeviceManager()
    
    // MARK: - State
    
    var switchState: AccountSwitchState = .idle
    var currentActiveAccount: AntigravityActiveAccount?

    
    // MARK: - Errors
    
    enum SwitchError: LocalizedError {
        case authFileNotFound(String)
        case tokenReadFailed(String)
        case ideRunningAndUserCancelled
        case databaseError(Error)
        case processError(Error)
        
        var errorDescription: String? {
            switch self {
            case .authFileNotFound(let path):
                return "Auth file not found: \(path)"
            case .tokenReadFailed(let reason):
                return "Failed to read token: \(reason)"
            case .ideRunningAndUserCancelled:
                return "IDE is running and user cancelled the switch"
            case .databaseError(let error):
                return "Database error: \(error.localizedDescription)"
            case .processError(let error):
                return "Process error: \(error.localizedDescription)"
            }
        }
    }
    
    // MARK: - Public API
    
    /// Check if Antigravity IDE database exists
    func isDatabaseAvailable() async -> Bool {
        await databaseService.databaseExists()
    }
    
    /// Check if Antigravity IDE is currently running
    func isIDERunning() -> Bool {
        processManager.isRunning()
    }
    
    /// Detect the currently active account in Antigravity IDE.
    /// Reads email directly from antigravityAuthStatus in the database.
    /// Returns `true` if reconcile materialised a new auth file that did not exist before.
    @discardableResult
    func detectActiveAccount() async -> Bool {
        guard !switchState.isInProgress else { return false }
        return await detectActiveAccountUnguarded(force: false)
    }

    @discardableResult
    private func detectActiveAccountUnguarded(force: Bool = false) async -> Bool {
        do {
            guard let activeEmail = try await databaseService.getActiveEmail(),
                  !activeEmail.isEmpty else {
                currentActiveAccount = nil
                return false
            }

            currentActiveAccount = AntigravityActiveAccount(
                email: activeEmail,
                detectedAt: Date()
            )

            let authDir = NSString(string: "~/.cli-proxy-api").expandingTildeInPath
            let targetPath = (authDir as NSString).appendingPathComponent("antigravity-\(activeEmail).json")
            let fileExistedBefore = FileManager.default.fileExists(atPath: targetPath)

            await reconcileAuthFileFromDB(email: activeEmail, force: force)

            let fileExistsAfter = FileManager.default.fileExists(atPath: targetPath)
            return !fileExistedBefore && fileExistsAfter
        } catch {
            Log.quota("[detectActiveAccount] error reading DB: \(error)")
            currentActiveAccount = nil
            return false
        }
    }
    
    /// Check if a given email matches the currently active account
    func isActiveAccount(email: String) -> Bool {
        guard let active = currentActiveAccount else { return false }
        return active.matches(email: email)
    }
    
    /// Begin the account switch confirmation flow
    func beginSwitch(accountId: String, accountEmail: String) {
        switchState = .confirming(accountId: accountId, accountEmail: accountEmail)
    }
    
    /// Cancel the current switch operation
    func cancelSwitch() {
        switchState = .idle
    }
    
    /// Execute the account switch
    /// - Parameters:
    ///   - authFilePath: Path to the Antigravity auth file (e.g., ~/.cli-proxy-api/antigravity-user@gmail.com.json)
    ///   - shouldRestartIDE: Whether to restart the IDE after injection (only if it was running)
    func executeSwitch(authFilePath: String, shouldRestartIDE: Bool = true) async {
        switchState = .switching(progress: .refreshingToken)
        
        let url = URL(fileURLWithPath: (authFilePath as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url),
              var authFile = try? JSONDecoder().decode(AntigravityAuthFile.self, from: data) else {
            switchState = .failed(message: "Failed to read auth file")
            return
        }

        let wasIDERunning = processManager.isRunning()

        do {
            // Step 0: Ensure token is fresh
            if authFile.isExpired, let refreshToken = authFile.refreshToken {
                do {
                    let freshToken = try await quotaFetcher.refreshAccessToken(refreshToken: refreshToken)
                    authFile.accessToken = freshToken
                    authFile.expired = cliExpiryString(from: Date().addingTimeInterval(3600))

                    // Use read-modify-write to preserve all existing fields (including `disabled`)
                    if let originalData = try? Data(contentsOf: url),
                       var json = try? JSONSerialization.jsonObject(with: originalData) as? [String: Any] {
                        json["access_token"] = freshToken
                        json["expired"] = authFile.expired
                        if let updatedData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                            let tmpURL = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)")
                            let fm = FileManager.default
                            do {
                                try updatedData.write(to: tmpURL, options: .atomic)
                                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpURL.path)
                                _ = try? fm.replaceItem(at: url, withItemAt: tmpURL, backupItemName: nil, options: [], resultingItemURL: nil)
                                if fm.fileExists(atPath: tmpURL.path) { try? fm.removeItem(at: tmpURL) }
                            } catch {
                                try? fm.removeItem(at: tmpURL)
                            }
                        }
                    }
                } catch {
                    switchState = .failed(message: "Token refresh failed: \(error.localizedDescription)")
                    return
                }
            }

            // Check cancellation before proceeding
            guard !Task.isCancelled else {
                switchState = .idle
                return
            }

            // Step 1: Detect version format before closing IDE
            let versionFormat = AntigravityVersionDetector.detectFormat()

            // Step 2: Close IDE if running
            if wasIDERunning {
                switchState = .switching(progress: .closingIDE)
            }
            let terminated = await processManager.terminateAllProcesses()
            if !terminated && processManager.isRunning() {
                throw SwitchError.processError(AntigravityProcessManager.ProcessError.terminationFailed)
            }

            await databaseService.cleanupWALFiles()

            let settleDelay: UInt64 = wasIDERunning ? 500_000_000 : 200_000_000
            try? await Task.sleep(nanoseconds: settleDelay)

            // Check cancellation after IDE close
            guard !Task.isCancelled else {
                switchState = .idle
                return
            }

            // Step 3: Create backup
            switchState = .switching(progress: .creatingBackup)
            try await databaseService.createBackup()

            // Check cancellation
            guard !Task.isCancelled else {
                switchState = .idle
                return
            }

            // Step 4: Inject device profile into storage.json
            switchState = .switching(progress: .injectingCredentials)

            let deviceProfile = await deviceManager.loadOrCreateProfile(forEmail: authFile.email)
            do {
                try await deviceManager.writeProfileToStorage(deviceProfile)
                try await databaseService.syncServiceMachineId(deviceProfile.devDeviceId)
            } catch {
                Log.warning("Device profile injection failed (non-fatal): \(error)")
            }

            // Check cancellation
            guard !Task.isCancelled else {
                switchState = .idle
                return
            }

            // Step 5: Inject token (version-aware)
            let expiry: Int64
            if let expired = authFile.expired,
               let expiryDate = ISO8601DateFormatter().date(from: expired) {
                expiry = Int64(expiryDate.timeIntervalSince1970)
            } else {
                expiry = Int64(Date().timeIntervalSince1970) + 3600
            }

            try await databaseService.injectToken(
                accessToken: authFile.accessToken,
                refreshToken: authFile.refreshToken ?? "",
                expiry: expiry,
                email: authFile.email,
                versionFormat: versionFormat
            )

            let keychainSyncOK: Bool
            if UserDefaults.standard.object(forKey: "syncAntigravityCLI") == nil || UserDefaults.standard.bool(forKey: "syncAntigravityCLI") {
                let expiryStringForCLI: String
                if let expired = authFile.expired {
                    expiryStringForCLI = expired
                } else {
                    expiryStringForCLI = cliExpiryString(from: Date(timeIntervalSince1970: TimeInterval(expiry)))
                }
                keychainSyncOK = KeychainHelper.saveAntigravityCLICredential(
                    accessToken: authFile.accessToken,
                    refreshToken: authFile.refreshToken ?? "",
                    expiry: expiryStringForCLI
                )
                if !keychainSyncOK {
                    Log.warning("[executeSwitch] non-fatal: failed to update Antigravity CLI keychain")
                }
            } else {
                keychainSyncOK = true
                Log.debug("[executeSwitch] skipped Antigravity CLI keychain update (sync disabled)")
            }

            // Check cancellation
            guard !Task.isCancelled else {
                switchState = .idle
                return
            }

            // Step 6: Restart IDE if it was running
            if wasIDERunning && shouldRestartIDE {
                switchState = .switching(progress: .restartingIDE)
                try await processManager.launch()
            }

            // Step 7: Clean up
            await databaseService.removeBackup()

            await detectActiveAccountUnguarded(force: true)

            let accountId = url.lastPathComponent
                .replacingOccurrences(of: "antigravity-", with: "")
                .replacingOccurrences(of: ".json", with: "")

            if keychainSyncOK {
                switchState = .success(accountId: accountId)
            } else {
                switchState = .partialSuccess(
                    accountId: accountId,
                    routingIssue: "CLI keychain sync failed"
                )
            }
            
        } catch {
            if await databaseService.backupExists() {
                do {
                    try await databaseService.restoreFromBackup()
                } catch {
                    Log.error("Rollback failed: \(error)")
                }
            }

            await detectActiveAccountUnguarded(force: true)
            switchState = .failed(message: error.localizedDescription)
        }
    }
    
    /// Execute switch using account email to find the auth file
    func executeSwitchForEmail(_ email: String, authDir: String = "~/.cli-proxy-api") async {
        let expandedPath = NSString(string: authDir).expandingTildeInPath
        
        // Build expected filename: antigravity-user@gmail.com.json
        let sanitizedEmail = email
            .replacingOccurrences(of: "@", with: ".")
            .replacingOccurrences(of: ".", with: "_")
        
        // Try different filename patterns
        let possibleFilenames = [
            "antigravity-\(email).json",
            "antigravity-\(sanitizedEmail).json",
            "antigravity-\(email.replacingOccurrences(of: "@gmail.com", with: ".gmail.com").replacingOccurrences(of: ".", with: "_")).json"
        ]
        
        var foundPath: String?
        for filename in possibleFilenames {
            let path = (expandedPath as NSString).appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: path) {
                foundPath = path
                break
            }
        }
        
        // If not found by email, scan directory
        if foundPath == nil {
            if let files = try? FileManager.default.contentsOfDirectory(atPath: expandedPath) {
                for file in files where file.hasPrefix("antigravity-") && file.hasSuffix(".json") {
                    let filePath = (expandedPath as NSString).appendingPathComponent(file)
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
                       let authFile = try? JSONDecoder().decode(AntigravityAuthFile.self, from: data),
                       authFile.email == email {
                        foundPath = filePath
                        break
                    }
                }
            }
        }
        
        if foundPath == nil {
            foundPath = await reconcileAuthFileFromDB(email: email, authDir: authDir)
        }

        guard let authFilePath = foundPath else {
            switchState = .failed(message: "Auth file not found for \(email)")
            return
        }
        
        await executeSwitch(authFilePath: authFilePath)
    }

    // MARK: - Helpers

    /// Formats a Date as an ISO8601 string with fractional seconds, matching the
    /// RFC3339Nano format produced by the live Antigravity CLI Go binary
    /// (e.g. "2026-05-24T12:34:56.789012345Z").
    private func cliExpiryString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: -

    /// Materialise or refresh a `~/.cli-proxy-api/antigravity-<email>.json` from the live
    /// Antigravity DB session.  Only acts when the DB active email matches `email`
    /// (case-insensitive, trimmed).  Uses read-modify-write so unrelated fields
    /// (`disabled`, `prefix`, `project_id`, `proxy_url`) are preserved.
    /// Returns the file path on success, nil on any failure.
    @discardableResult
    private func reconcileAuthFileFromDB(
        email: String,
        authDir: String = "~/.cli-proxy-api",
        force: Bool = false
    ) async -> String? {
        guard force || !switchState.isInProgress else {
            Log.quota("[reconcile] skipped — switch in progress")
            return nil
        }
        Log.quota("[reconcile] start for \(Log.maskEmail(email))")

        guard let dbEmail = try? await databaseService.getActiveEmail(),
              !dbEmail.isEmpty,
              dbEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else {
            Log.quota("[reconcile] DB email mismatch or missing — aborting")
            return nil
        }

        guard let tokenInfo = try? await databaseService.getCurrentTokenInfo() else {
            Log.quota("[reconcile] getCurrentTokenInfo returned nil — aborting")
            return nil
        }
        guard let accessToken = tokenInfo.accessToken, !accessToken.isEmpty else {
            Log.quota("[reconcile] access_token missing or empty — aborting")
            return nil
        }

        let expandedDir = NSString(string: authDir).expandingTildeInPath
        let targetPath = (expandedDir as NSString).appendingPathComponent("antigravity-\(email).json")

        let now = Date()
        let expiryDate: Date
        if let epochSeconds = tokenInfo.expiry {
            expiryDate = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
        } else {
            expiryDate = now.addingTimeInterval(3600)
        }
        let expiresIn = max(0, Int(expiryDate.timeIntervalSince(now)))
        let expiredString = cliExpiryString(from: expiryDate)
        let timestampMs = Int(now.timeIntervalSince1970 * 1000)

        let fm = FileManager.default

        if !fm.fileExists(atPath: expandedDir) {
            try? fm.createDirectory(atPath: expandedDir, withIntermediateDirectories: true)
        }

        let url = URL(fileURLWithPath: targetPath)

        var json: [String: Any]
        var existingMatches = false
        if fm.fileExists(atPath: targetPath),
           let existingData = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            json = existing
            
            let extAccessToken = existing["access_token"] as? String
            let extEmail = existing["email"] as? String
            let extExpired = existing["expired"] as? String
            let extRefreshToken = existing["refresh_token"] as? String
            
            let newRefreshToken = tokenInfo.refreshToken ?? ""
            
            if extAccessToken == accessToken,
               extEmail == email,
               extExpired == expiredString,
               (extRefreshToken ?? "") == newRefreshToken {
                existingMatches = true
            }
        } else {
            json = [:]
        }

        if existingMatches {
            Log.quota("[reconcile] auth file is identical on disk — skipping write: \(targetPath)")
            return targetPath
        }

        json["access_token"] = accessToken
        json["email"] = email
        json["expired"] = expiredString
        json["expires_in"] = expiresIn
        json["timestamp"] = timestampMs
        json["type"] = "antigravity"
        if let refreshToken = tokenInfo.refreshToken, !refreshToken.isEmpty {
            json["refresh_token"] = refreshToken
        }
        if json["disabled"] == nil {
            json["disabled"] = false
        }

        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }

        let tmpURL = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmpURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpURL.path)
            _ = try? fm.replaceItem(at: url, withItemAt: tmpURL, backupItemName: nil, options: [], resultingItemURL: nil)
            if fm.fileExists(atPath: tmpURL.path) {
                try? fm.removeItem(at: tmpURL)
            }
        } catch {
            try? fm.removeItem(at: tmpURL)
            return nil
        }

        Log.quota("[reconcile] wrote auth file: \(targetPath)")
        // Keychain write intentionally omitted here — background reconcile must not
        // touch the external keychain item on every timer tick. Keychain sync only
        // happens in executeSwitch and persistRefreshedToken.

        return targetPath
    }
    
    /// Retry the last failed switch
    func retrySwitch() async {
        guard case .failed = switchState else { return }
        // Reset and let UI trigger a new switch
        switchState = .idle
    }
    
    /// Dismiss success/failure state
    func dismissResult() {
        switchState = .idle
    }
}
