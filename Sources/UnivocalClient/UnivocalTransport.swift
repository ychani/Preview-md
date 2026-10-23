// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import Foundation

/// What a transport reports to the client, in order.
enum TransportEvent: Sendable {
    /// One complete message (an NDJSON frame without its newline, or one WebSocket text frame).
    case message(Data)
    /// The transport closed. `nil` = orderly EOF.
    case closed(UnivocalError?)
}

/// A bidirectional message pipe to the server. Implementations run their I/O on
/// a private queue; `events` preserves arrival order and finishes after `.closed`.
protocol UnivocalTransport: AnyObject, Sendable {
    var kind: UnivocalTransportKind { get }
    var events: AsyncStream<TransportEvent> { get }
    /// Resolves once the transport is connected; throws `transportFailure` otherwise.
    func open() async throws
    /// Sends one NDJSON frame (message + `\n`). Fire-and-forget, ordered.
    func send(frame: Data)
    func close()
}

/// Inbound frames from the server can be larger than what we send; cap them anyway.
let inboundMaxFrameBytes = 16 * 1_048_576
