// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import Foundation

/// Every error the SDK throws or reports on a session stream.
///
/// Server codes mirror SPEC §10 one-to-one; client-side codes describe failures
/// that never reach the wire (not installed, launch timeout, consent, …).
public struct UnivocalError: Error, Sendable, Equatable {
    public enum Code: String, Sendable, Codable {
        // server codes (SPEC §10)
        case protocolError, unsupportedVersion, unauthorized, unknownType, invalidArgument, sessionExists,
             noSession, notOwner, busy, invalidOffset, limitExceeded, rateLimited, engineUnavailable,
             engineError, slowConsumer, internalError = "internal"
        // client-side codes
        case notInstalled, notRunning, launchTimedOut, consentDenied, consentTimedOut, disconnected,
             transportFailure, textTooLarge, sessionEnded
    }

    public var code: Code
    public var message: String
    public var fatal: Bool
    /// e.g. "revoked", "identityMismatch", "user", "timeout", "disabled", "rateLimited".
    public var reason: String?
    public var sessionId: String?

    public init(code: Code, message: String = "", fatal: Bool = false, reason: String? = nil, sessionId: String? = nil) {
        self.code = code
        self.message = message
        self.fatal = fatal
        self.reason = reason
        self.sessionId = sessionId
    }
}

extension UnivocalError: LocalizedError {
    public var errorDescription: String? { message }
}

extension UnivocalError {
    static func disconnected(_ message: String = "The connection to Univocal closed.", sessionId: String? = nil) -> UnivocalError {
        UnivocalError(code: .disconnected, message: message, fatal: true, sessionId: sessionId)
    }

    static func transport(_ message: String) -> UnivocalError {
        UnivocalError(code: .transportFailure, message: message, fatal: true)
    }

    /// Builds an error from a server `error` message (SPEC §5.8). Unknown codes map to `.internalError`.
    init(wire msg: JSONObject) {
        let codeString = msg.string("code") ?? "internal"
        self.init(
            code: Code(rawValue: codeString) ?? .internalError,
            message: msg.string("message") ?? codeString,
            fatal: msg.bool("fatal") ?? false,
            reason: msg.string("reason"),
            sessionId: msg.string("sessionId")
        )
    }
}
