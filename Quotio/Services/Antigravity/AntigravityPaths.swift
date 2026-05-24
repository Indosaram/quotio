//
//  AntigravityPaths.swift
//  Quotio
//

import Foundation

nonisolated enum AntigravityPaths {

    // MARK: - App Locations

    static let legacyAppSystem = "/Applications/Antigravity.app"

    static var legacyAppUser: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Antigravity.app").path
    }

    static let ideAppSystem = "/Applications/Antigravity IDE.app"

    static var ideAppUser: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Antigravity IDE.app").path
    }

    static var legacyAppPaths: [String] {
        [legacyAppSystem, legacyAppUser, ideAppSystem, ideAppUser]
    }

    // MARK: - Bundle Identifiers

    static let bundleIdentifiers: [String] = [
        "com.google.antigravity",
        "com.todesktop.230313mzl4w4u92"
    ]

    // MARK: - Application Support (disk-only)

    // Candidate folder names under ~/Library/Application Support.
    private static let appSupportCandidates: [String] = ["Antigravity", "Antigravity IDE"]

    // Relative path used to confirm an Application Support folder is the active one.
    private static let dbRelativePath = "User/globalStorage/state.vscdb"

    // Cached resolved base URL — computed once, reused on every call.
    private static let _resolvedAppSupportBase: URL = {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let appSupport = home.appendingPathComponent("Library/Application Support")

        // 1. Prefer the folder whose name matches the detected installed bundle.
        if let detectedName = detectedBundleName() {
            let candidate = appSupport.appendingPathComponent(detectedName)
            if fm.fileExists(atPath: candidate.appendingPathComponent(dbRelativePath).path) {
                return candidate
            }
        }

        // 2. Probe candidates for an existing DB.
        for name in appSupportCandidates {
            let candidate = appSupport.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.appendingPathComponent(dbRelativePath).path) {
                return candidate
            }
        }

        // 3. Safe fallback: Antigravity (original behaviour).
        return appSupport.appendingPathComponent("Antigravity")
    }()

    // Returns the CFBundleName read from an app bundle's Contents/Info.plist,
    // or nil if the plist is absent or the key is missing.
    private static func bundleName(at appPath: String) -> String? {
        let plistURL = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plistURL) as? [String: Any],
              let name = dict["CFBundleName"] as? String else { return nil }
        return name
    }

    // Walks legacyAppPaths and returns the CFBundleName of the first installed bundle found.
    private static func detectedBundleName() -> String? {
        for path in legacyAppPaths {
            if FileManager.default.fileExists(atPath: path),
               let name = bundleName(at: path) {
                return name
            }
        }
        return nil
    }

    // Disk-only base: resolves to the active Antigravity Application Support directory.
    // Prefers the detected install name when its DB exists; probes candidates; falls back to
    // ~/Library/Application Support/Antigravity. DatabaseService and DeviceManager use this;
    // ProcessManager does not.
    static func resolvedAppSupportBase() -> URL {
        _resolvedAppSupportBase
    }

    static func isAntigravityApp(at url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == "Antigravity.app" || name == "Antigravity IDE.app"
    }
}
