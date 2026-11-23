import Foundation

public struct MailboxReport: Sendable, Equatable {
    public var processed = 0
    /// Problems with single emails; those emails stay in the inbox for the next try.
    public var failures: [String] = []

    public init(processed: Int = 0, failures: [String] = []) {
        self.processed = processed
        self.failures = failures
    }
}

/// One pass over the mailbox: every email in INBOX is handed to `handle` and, once that
/// succeeded, moved to the Processed mailbox. Nothing is deleted.
public enum MailboxProcessor {
    public static let processedMailbox = "Processed"

    public static func run(
        session: IMAPSession, user: String, password: String,
        handle: @Sendable (Data) async throws -> Void
    ) async throws -> MailboxReport {
        try await session.start()
        try await session.login(user: user, password: password)
        try await session.createMailboxIfNeeded(processedMailbox)
        try await session.select("INBOX")

        var report = MailboxReport()
        for uid in try await session.allUIDs() {
            do {
                let raw = try await session.fetchMessage(uid: uid)
                // The documents must be safely stored before the email leaves the inbox.
                try await handle(raw)
                try await session.move(uid: uid, to: processedMailbox)
                report.processed += 1
            } catch let error as IMAPError where error == .connectionClosed {
                throw error
            } catch {
                report.failures.append(error.localizedDescription)
            }
        }
        await session.logout()
        return report
    }
}
