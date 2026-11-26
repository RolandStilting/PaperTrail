import Foundation

public struct MailboxReport: Sendable, Equatable {
    public var processed = 0
    /// Problems with single emails; those emails stay in the inbox for the next try.
    public var failures: [String] = []
    /// Emails that failed this time; the next pass handles them last.
    public var failedUIDs: Set<UInt32> = []
    /// Emails in the working folder and when this device first saw them there (see
    /// `MailboxProcessor.staleClaim`).
    public var workingSeen: [UInt32: Date] = [:]
    /// Emails another device was already filing; skipped.
    public var claimedElsewhere = 0

    public init(processed: Int = 0, failures: [String] = [], failedUIDs: Set<UInt32> = [], workingSeen: [UInt32: Date] = [:],
                claimedElsewhere: Int = 0) {
        self.processed = processed
        self.failures = failures
        self.failedUIDs = failedUIDs
        self.workingSeen = workingSeen
        self.claimedElsewhere = claimedElsewhere
    }
}

public enum MailboxError: LocalizedError, Equatable, Sendable {
    case folderNotFound(String)
    case unsafeSettings(String)
    case claimsUnsupported

    public var errorDescription: String? {
        switch self {
        case .folderNotFound(let folder):
            String(localized: "The mail folder \"\(folder)\" doesn't exist. Create it (or the mail rule that fills it) on icloud.com, or check the folder name in Settings → Email.", bundle: .module)
        case .unsafeSettings(let reason):
            reason
        case .claimsUnsupported:
            String(localized: "This mail server can't tell which device took an email (no UIDPLUS), so only one device may check it. Check email on the Mac only.", bundle: .module)
        }
    }
}

/// One pass over the mailbox: every email in the account's folder is handed to `handle` and,
/// once that succeeded, moved to the processed folder. Nothing is deleted.
///
/// Several devices may check the same mailbox. When the server supports it, each email is first
/// moved to the working folder: only the device whose move succeeds files it, then moves it on
/// to the processed folder (or back, when filing failed). An email left in the working folder
/// (a device stopped halfway) goes back after `staleClaim`.
public enum MailboxProcessor {
    /// After this long in the working folder, an email is considered abandoned.
    public static let staleClaim: TimeInterval = 60 * 60

    /// - Parameters:
    ///   - requireClaims: Refuse to run without claims (a device that isn't the only checker).
    ///   - workingSeenBefore: What the previous pass saw in the working folder.
    public static func run(
        session: IMAPSession, account: MailAccount, password: String, failedBefore: Set<UInt32> = [],
        requireClaims: Bool = false, workingSeenBefore: [UInt32: Date] = [:], now: Date = .now,
        handle: @Sendable (Data) async throws -> Void
    ) async throws -> MailboxReport {
        // Never touch a folder the settings don't allow, e.g. the Inbox of a personal account.
        if let problem = account.validationErrors.first { throw MailboxError.unsafeSettings(problem) }
        let folder = account.folder.trimmingCharacters(in: .whitespaces)
        let processedMailbox = account.processedFolder.trimmingCharacters(in: .whitespaces)

        try await session.start()
        try await signIn(session: session, account: account, password: password)
        do {
            try await session.select(folder)
        } catch IMAPError.commandFailed {
            await session.logout()
            throw MailboxError.folderNotFound(folder)
        }
        try await session.createMailboxIfNeeded(processedMailbox)
        let claims = await session.supportsClaims
        if requireClaims, !claims {
            await session.logout()
            throw MailboxError.claimsUnsupported
        }

        var report = MailboxReport()
        let working = MailAccount.workingFolder
        if claims {
            try await session.createMailboxIfNeeded(working)
            // Return abandoned claims: emails this device has seen in the working folder for too long.
            try await session.select(working)
            for uid in try await session.allUIDs() {
                let seen = workingSeenBefore[uid] ?? now
                if now.timeIntervalSince(seen) >= staleClaim {
                    _ = try await session.moveReturningUID(uid: uid, to: folder)
                } else {
                    report.workingSeen[uid] = seen
                }
            }
        }
        try await session.select(folder)

        // Emails that failed before go last, so they can't use up the time for new mail.
        let uids = try await session.allUIDs()
        for uid in uids.filter({ !failedBefore.contains($0) }) + uids.filter(failedBefore.contains) {
            do {
                let raw = try await session.fetchMessage(uid: uid)
                guard claims else {
                    // One device only: the documents must be safely stored before the email leaves.
                    do {
                        try await handle(raw)
                    } catch {
                        report.failures.append(error.localizedDescription)
                        report.failedUIDs.insert(uid)
                        continue
                    }
                    try await session.move(uid: uid, to: processedMailbox)
                    report.processed += 1
                    continue
                }
                guard let claimed = try await session.moveReturningUID(uid: uid, to: working) else {
                    report.claimedElsewhere += 1
                    continue
                }
                report.workingSeen[claimed] = now
                var failure: Error?
                do { try await handle(raw) } catch { failure = error }
                try await session.select(working)
                if let failure {
                    report.failures.append(failure.localizedDescription)
                    if let back = try await session.moveReturningUID(uid: claimed, to: folder) { report.failedUIDs.insert(back) }
                } else {
                    try await session.move(uid: claimed, to: processedMailbox)
                    report.processed += 1
                }
                report.workingSeen[claimed] = nil
                try await session.select(folder)
            } catch let error as IMAPError where error == .connectionClosed {
                throw error
            } catch {
                report.failures.append(error.localizedDescription)
                report.failedUIDs.insert(uid)
            }
        }
        await session.logout()
        return report
    }

    /// Apple's iCloud Mail help: the user name is usually the name before @icloud.com, but
    /// some apps need the full address. For iCloud, a failed short name is retried in full.
    public static func signIn(session: IMAPSession, account: MailAccount, password: String) async throws {
        let user = account.username.trimmingCharacters(in: .whitespaces)
        do {
            try await session.login(user: user, password: password)
        } catch IMAPError.loginFailed(let first) where account.isICloud && !user.contains("@") {
            do {
                try await session.login(user: "\(user)@icloud.com", password: password)
            } catch IMAPError.loginFailed {
                throw IMAPError.loginFailed(first)
            }
        }
    }
}
