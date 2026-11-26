#if os(macOS)
import Foundation
import Observation
import PaperTrailKit

nonisolated enum MailIntakeError: LocalizedError {
    case nothingToFile(String)
    case missingPassword

    var errorDescription: String? {
        switch self {
        case .nothingToFile(let subject):
            String(localized: "The email \"\(subject)\" has no PDF, image or text to file. It stays in the mailbox; move it out yourself.")
        case .missingPassword:
            String(localized: "No mailbox password is saved. Enter the app-specific password in Settings → Email.")
        }
    }
}

/// Checks the dedicated mailbox on the Mac and puts every email's documents in Needs Review.
/// Emails are moved to "Processed" only after their documents are safely written.
@Observable @MainActor
final class MailIntakeService {
    enum Status: Equatable {
        case off
        case idle
        case checking
        case checked(Date, filed: Int)
        case failed(String)
    }

    static let accountKey = "mailAccount.v1"

    private(set) var status = Status.off
    private(set) var account: MailAccount
    /// Problems with single emails from the last check (shown in the menu).
    private(set) var problems: [String] = []

    private let filingService: FilingService
    private let passwords = KeychainPasswordStore()
    private var timer: Task<Void, Never>?
    /// Emails that failed in the last check; the next check handles them last.
    private var failedUIDs: Set<UInt32> = []
    /// Attachments skipped during the current check (too large, not a PDF, too many).
    private var skipped: [String] = []

    init(filingService: FilingService) {
        self.filingService = filingService
        let stored = UserDefaults.standard.data(forKey: Self.accountKey).flatMap { try? JSONDecoder().decode(MailAccount.self, from: $0) }
        account = stored ?? MailAccount()
        status = account.isEnabled ? .idle : .off
    }

    var hasPassword: Bool { ((try? passwords.password(account: account.username)) ?? nil) != nil }

    /// Saves the settings; a non-empty password replaces the stored one.
    func update(_ newAccount: MailAccount, password: String) throws {
        if !password.isEmpty {
            try passwords.save(password, account: newAccount.username)
        } else if newAccount.username != account.username, let old = try passwords.password(account: account.username) {
            try passwords.save(old, account: newAccount.username)
        }
        account = newAccount
        UserDefaults.standard.set(try JSONEncoder().encode(newAccount), forKey: Self.accountKey)
        status = newAccount.isEnabled ? .idle : .off
        start()
    }

    /// Checks now and then every few minutes while the app runs.
    func start() {
        timer?.cancel()
        guard account.isEnabled else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkNow()
                let minutes = max(1, self?.account.checkIntervalMinutes ?? 5)
                try? await Task.sleep(for: .seconds(minutes * 60))
            }
        }
    }

    func checkNow() async {
        guard account.isEnabled, account.isComplete, status != .checking else { return }
        status = .checking
        do {
            guard let password = try passwords.password(account: account.username) else { throw MailIntakeError.missingPassword }
            let root = try await filingService.location.resolveRoot().url
            skipped = []
            let report = try await Self.runPass(account: account, password: password, limit: 300, failedBefore: failedUIDs) { raw in
                try await self.file(raw, root: root)
            }
            failedUIDs = report.failedUIDs
            problems = report.failures + skipped
            status = .checked(.now, filed: report.processed)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Signs in and out again, to check the settings.
    func testConnection(_ account: MailAccount, password: String) async -> String? {
        if let problem = account.validationErrors.first { return problem }
        do {
            let transport = try await TLSTransport.connect(host: account.server, port: account.port)
            let watchdog = Self.closeAfter(seconds: 30, transport)
            defer { watchdog.cancel(); transport.close() }
            let session = IMAPSession(transport: transport)
            try await session.start()
            try await MailboxProcessor.signIn(session: session, account: account, password: password)
            let folder = account.folder.trimmingCharacters(in: .whitespaces)
            do {
                // Read-only check: SELECT doesn't change anything in the folder.
                try await session.select(folder)
            } catch IMAPError.commandFailed {
                await session.logout()
                return MailboxError.folderNotFound(folder).localizedDescription
            }
            await session.logout()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private nonisolated static func runPass(account: MailAccount, password: String, limit: Double, failedBefore: Set<UInt32>,
                                           handle: @escaping @Sendable (Data) async throws -> Void) async throws -> MailboxReport {
        let transport = try await TLSTransport.connect(host: account.server, port: account.port)
        let watchdog = closeAfter(seconds: limit, transport)
        defer { watchdog.cancel(); transport.close() }
        return try await MailboxProcessor.run(session: IMAPSession(transport: transport), account: account, password: password,
                                         failedBefore: failedBefore, handle: handle)
    }

    /// Closing the connection ends any read that is still waiting, so a silent server
    /// can't hang the check.
    private nonisolated static func closeAfter(seconds: Double, _ transport: TLSTransport) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { transport.close() }
        }
    }

    /// Writes one email's documents to Needs Review. All documents are made first and only
    /// then written, so an email that fails halfway doesn't leave copies behind that come back
    /// on every check. A document that can't be converted is skipped and reported; if none
    /// can, this throws and the email stays in the mailbox.
    private func file(_ raw: Data, root: URL) async throws {
        // Parsing can be heavy for a large email: off the main actor.
        let (message, selection) = await Task.detached(priority: .utility) {
            let message = MIMEParser.parse(raw)
            return (message, EmailIntake.select(in: message))
        }.value
        let subject = message.subject.isEmpty ? message.from : message.subject
        skipped += selection.skipped.map { String(localized: "\(subject): \($0)") }
        guard !selection.documents.isEmpty else { throw MailIntakeError.nothingToFile(message.subject) }
        let received = EmailIntake.receivedDate(header: message.date)
        let label = EmailIntake.label(for: message)
        let renderer = HTMLPDFRenderer()
        var pendings: [PendingDocument] = []
        var firstError: Error?
        for document in selection.documents {
            do {
                switch document {
                case .pdf(let name, let data):
                    pendings.append(PendingDocument(pdfData: data, source: .email, originalName: name))
                case .image(let name, let data):
                    let pdf = try await Task.detached(priority: .utility) {
                        try PDFBuilder.makePDF(from: PDFBuilder.images(fromImageData: data))
                    }.value
                    pendings.append(PendingDocument(pdfData: pdf, source: .email, originalName: name))
                case .html(let html):
                    pendings.append(PendingDocument(pdfData: try await renderer.pdf(html: html), source: .email, originalName: label))
                case .text(let text):
                    pendings.append(PendingDocument(pdfData: try await renderer.pdf(text: text), source: .email, originalName: label))
                }
            } catch {
                firstError = firstError ?? error
                skipped.append(String(localized: "\(subject): \(error.localizedDescription)"))
            }
        }
        guard !pendings.isEmpty else { throw firstError ?? MailIntakeError.nothingToFile(message.subject) }
        for pending in pendings {
            _ = try await filingService.reviewQueue.add(pending, root: root, now: received)
        }
    }
}

#endif
