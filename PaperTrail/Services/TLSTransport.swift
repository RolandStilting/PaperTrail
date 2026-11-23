import Foundation
import Network
import PaperTrailKit

nonisolated enum MailConnectionError: LocalizedError {
    case couldNotConnect(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .couldNotConnect(let reason):
            String(localized: "Could not connect to the mail server: \(reason) Check the server name and your internet connection.")
        case .timedOut:
            String(localized: "The mail server did not answer in time. Paper Trail will try again at the next check.")
        }
    }
}

/// A TLS connection (system certificate checks) for IMAPSession.
nonisolated final class TLSTransport: IMAPTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "PaperTrail.IMAP")

    private init(host: String, port: Int) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(clamping: port)), using: .tls)
    }

    static func connect(host: String, port: Int) async throws -> TLSTransport {
        let transport = TLSTransport(host: host, port: port)
        try await transport.open()
        return transport
    }

    private func open() async throws {
        let resumed = LockedFlag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.set() { continuation.resume() }
                case .failed(let error):
                    if resumed.set() { continuation.resume(throwing: MailConnectionError.couldNotConnect(error.localizedDescription)) }
                case .waiting(let error):
                    if resumed.set() { continuation.resume(throwing: MailConnectionError.couldNotConnect(error.localizedDescription)) }
                case .cancelled:
                    if resumed.set() { continuation.resume(throwing: MailConnectionError.timedOut) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 20) { [connection] in
                if !resumed.isSet { connection.cancel() }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func close() {
        connection.cancel()
    }
}

nonisolated final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    /// Sets the flag; true only for the first caller.
    func set() -> Bool { lock.withLock { defer { value = true }; return !value } }
    var isSet: Bool { lock.withLock { value } }
}
