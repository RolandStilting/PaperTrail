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

public enum MailboxError: LocalizedError, Equatable, Sendable {
    case folderNotFound(String)
    case unsafeSettings(String)

    public var errorDescription: String? {
        switch self {
        case .folderNotFound(let folder):
            String(localized: "The mail folder \"\(folder)\" doesn't exist. Create it (or the mail rule that fills it) on icloud.com, or check the folder name in Settings → Email.", bundle: .module)
        case .unsafeSettings(let reason):
            reason
        }
    }
}

/// One pass over the mailbox: every email in the account's folder is handed to `handle` and,
/// once that succeeded, moved to the processed folder. Nothing is deleted.
public enum MailboxProcessor {
    public static func run(
        session: IMAPSession, account: MailAccount, password: String,
        handle: @Sendable (Data) async throws -> Void
    ) async throws -> MailboxReport {
        // Never touch a folder the settings don't allow, e.g. the Inbox of a personal account.
        if let problem = account.validationErrors.first { throw MailboxError.unsafeSettings(problem) }
        let folder = account.folder.trimmingCharacters(in: .whitespaces)
        let processedMailbox = account.processedFolder.trimmingCharacters(in: .whitespaces)

        try await session.start()
        try await session.login(user: account.username, password: password)
        do {
            try await session.select(folder)
        } catch IMAPError.commandFailed {
            await session.logout()
            throw MailboxError.folderNotFound(folder)
        }
        try await session.createMailboxIfNeeded(processedMailbox)
        try await session.select(folder)

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
