//
//  AntigravityActiveAccount.swift
//  Quotio
//
//  Model for tracking the currently active Antigravity account in Antigravity.app.
//

import Foundation

/// Represents the currently active Antigravity account in Antigravity.app
struct AntigravityActiveAccount: Equatable, Sendable {
    /// Email of the active account (from antigravityAuthStatus in database)
    let email: String
    
    /// When the active account was last detected
    let detectedAt: Date
    
    /// Check if this matches a given email
    func matches(email: String) -> Bool {
        guard !self.email.isEmpty, !email.isEmpty else { return false }
        return self.email.lowercased() == email.lowercased()
    }
}

/// State for account switching operation
enum AccountSwitchState: Equatable {
    case idle
    case confirming(accountId: String, accountEmail: String)
    case switching(progress: SwitchProgress)
    case success(accountId: String)
    case partialSuccess(accountId: String, routingIssue: String)
    case failed(message: String)
    
    enum SwitchProgress: String, Equatable {
        case refreshingToken = "Preparing token..."
        case closingIDE = "Closing Antigravity.app..."
        case creatingBackup = "Creating backup..."
        case injectingCredentials = "Injecting credentials..."
        case restartingIDE = "Restarting Antigravity.app..."
    }
    
    var isInProgress: Bool {
        switch self {
        case .confirming, .switching:
            return true
        default:
            return false
        }
    }
}
