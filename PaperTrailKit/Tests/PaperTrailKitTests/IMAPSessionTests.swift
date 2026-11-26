import Foundation
import Testing
@testable import PaperTrailKit

/// A scripted IMAP server: answers each command by matching its text (without the tag).
final class ScriptedIMAPServer: IMAPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Data] = []
    private(set) var commands: [String] = []
    let answer: @Sendable (String) -> String

    init(greeting: String = "* OK IMAP ready\r\n", answer: @escaping @Sendable (String) -> String) {
        self.answer = answer
        pending = [Data(greeting.utf8)]
    }

    private var continuationTag: String?

    func send(_ data: Data) async throws {
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        lock.withLock {
            var tag = String(line.prefix { $0 != " " })
            var command = String(line.dropFirst(tag.count + 1))
            if let waiting = continuationTag {
                // A continuation line has no tag of its own.
                tag = waiting
                command = "CONTINUATION " + line
                continuationTag = nil
            }
            commands.append(command)
            let reply = answer(command)  // once: a stateful server changes on each answer
            if reply.hasPrefix("+") { continuationTag = tag }
            // Split long responses in two chunks to exercise buffering.
            let response = Data(reply.replacingOccurrences(of: "TAG", with: tag).utf8)
            let half = response.count / 2
            pending.append(response.prefix(half))
            pending.append(response.dropFirst(half))
        }
    }

    func receive() async throws -> Data {
        lock.withLock { pending.isEmpty ? Data() : pending.removeFirst() }
    }
}

@Suite("IMAPSession")
struct IMAPSessionTests {
    static let account = MailAccount(isEnabled: true, address: "archief@icloud.example", username: "archief")
    static let message = "From: a@example.com\r\nSubject: Bon\r\n\r\nBedrag 12,50\r\n"

    /// A server without UIDPLUS: one device only, emails are moved straight to Processed.
    static func server(move: Bool = true, failFetchOf failing: UInt32? = nil) -> ScriptedIMAPServer {
        ScriptedIMAPServer { command in
            switch command {
            case let c where c.hasPrefix("LOGIN"):
                c == #"LOGIN "archief" "abcd-efgh-ijkl-mnop""# ? "TAG OK logged in\r\n" : "TAG NO [AUTHENTICATIONFAILED] Invalid credentials\r\n"
            case "CAPABILITY":
                "* CAPABILITY IMAP4rev1\(move ? " MOVE" : "")\r\nTAG OK\r\n"
            case #"CREATE "Paper Trail Processed""#:
                "TAG NO [ALREADYEXISTS] Mailbox exists\r\n"
            case #"LIST "" "Paper Trail Processed""#:
                "* LIST () \"/\" \"Paper Trail Processed\"\r\nTAG OK\r\n"
            case #"SELECT "Paper Trail""#:
                "* 2 EXISTS\r\nTAG OK [READ-WRITE] selected\r\n"
            case let c where c.hasPrefix("SELECT"):
                "TAG NO [NONEXISTENT] Unknown Mailbox\r\n"
            case "UID SEARCH ALL":
                "* SEARCH 7 9\r\nTAG OK\r\n"
            case let c where c.hasPrefix("UID FETCH"):
                c.hasPrefix("UID FETCH \(failing ?? 0) ") ? "TAG NO message gone\r\n"
                    : "* 1 FETCH (UID 7 BODY[] {\(message.utf8.count)}\r\n\(message))\r\nTAG OK\r\n"
            default:
                "TAG OK\r\n"
            }
        }
    }

    @Test func processesAndMovesEveryEmail() async throws {
        let server = Self.server()
        let received = LockedList()
        let report = try await MailboxProcessor.run(session: IMAPSession(transport: server), account: Self.account, password: "abcd-efgh-ijkl-mnop") { raw in
            received.append(raw)
        }
        #expect(report == MailboxReport(processed: 2))
        #expect(received.items.map { String(decoding: $0, as: UTF8.self) } == [Self.message, Self.message])
        #expect(server.commands.contains(#"UID MOVE 7 "Paper Trail Processed""#))
        #expect(server.commands.contains(#"UID MOVE 9 "Paper Trail Processed""#))
        #expect(server.commands.last == "LOGOUT")
    }

    @Test func withoutMoveCopiesFlagsAndExpunges() async throws {
        let server = Self.server(move: false)
        _ = try await MailboxProcessor.run(session: IMAPSession(transport: server), account: Self.account, password: "abcd-efgh-ijkl-mnop") { _ in }
        #expect(server.commands.contains(#"UID COPY 7 "Paper Trail Processed""#))
        #expect(server.commands.contains(#"UID STORE 7 +FLAGS.SILENT (\Deleted)"#))
        #expect(server.commands.contains("EXPUNGE"))
    }

    @Test func failedEmailStaysInInbox() async throws {
        let server = Self.server(failFetchOf: 9)
        let report = try await MailboxProcessor.run(session: IMAPSession(transport: server), account: Self.account, password: "abcd-efgh-ijkl-mnop") { _ in }
        #expect(report.processed == 1)
        #expect(report.failures.count == 1)
        #expect(!server.commands.contains(#"UID MOVE 9 "Paper Trail Processed""#))
    }

    @Test func handlerFailureKeepsEmail() async throws {
        let server = Self.server()
        struct Boom: Error {}
        let report = try await MailboxProcessor.run(session: IMAPSession(transport: server), account: Self.account, password: "abcd-efgh-ijkl-mnop") { _ in throw Boom() }
        #expect(report.processed == 0)
        #expect(!server.commands.contains { $0.hasPrefix("UID MOVE") })
    }

    @Test func wrongPasswordIsALoginErrorWithoutThePassword() async throws {
        let server = Self.server()
        do {
            _ = try await MailboxProcessor.run(session: IMAPSession(transport: server), account: Self.account, password: "wrong-secret") { _ in }
            Issue.record("expected a login error")
        } catch let error as IMAPError {
            #expect(error == .loginFailed("NO [AUTHENTICATIONFAILED] Invalid credentials"))
            #expect(!(error.errorDescription ?? "").contains("wrong-secret"))
        }
    }

    @Test func quotesStrings() {
        #expect(IMAPSession.quoted(#"a"b\c"#) == #""a\"b\\c""#)
        #expect(IMAPSession.literalSize(atEndOf: "* 1 FETCH (BODY[] {123}") == 123)
        #expect(IMAPSession.literalSize(atEndOf: "* OK done") == nil)
    }
}

@Suite("IMAP sign-in")
struct IMAPSignInTests {
    static let plain = Data("\u{0}archief\u{0}abcd-efgh-ijkl-mnop".utf8).base64EncodedString()

    static func server(capabilities: String, acceptedUser: String = "archief") -> ScriptedIMAPServer {
        let accepted = Data("\u{0}\(acceptedUser)\u{0}abcd-efgh-ijkl-mnop".utf8).base64EncodedString()
        return ScriptedIMAPServer { command in
            switch command {
            case "CAPABILITY": "* CAPABILITY IMAP4rev1 \(capabilities)\r\nTAG OK\r\n"
            case "AUTHENTICATE PLAIN": "+ \r\n"
            case "CONTINUATION \(accepted)", "AUTHENTICATE PLAIN \(accepted)": "TAG OK authenticated\r\n"
            case let c where c.hasPrefix("AUTHENTICATE") || c.hasPrefix("CONTINUATION") || c.hasPrefix("LOGIN"):
                "TAG NO [AUTHENTICATIONFAILED] Authentication failed.\r\n"
            default: "TAG OK\r\n"
            }
        }
    }

    @Test func usesSaslPlainWithInitialResponse() async throws {
        let server = Self.server(capabilities: "AUTH=PLAIN SASL-IR")
        let session = IMAPSession(transport: server)
        try await session.start()
        try await session.login(user: "archief", password: "abcd-efgh-ijkl-mnop")
        #expect(server.commands.contains("AUTHENTICATE PLAIN \(Self.plain)"))
        #expect(!server.commands.contains { $0.hasPrefix("LOGIN") })
    }

    @Test func usesSaslPlainWithContinuation() async throws {
        let server = Self.server(capabilities: "AUTH=PLAIN")
        let session = IMAPSession(transport: server)
        try await session.start()
        try await session.login(user: "archief", password: "abcd-efgh-ijkl-mnop")
        #expect(server.commands.contains("CONTINUATION \(Self.plain)"))
    }

    @Test func iCloudRetriesWithFullAddress() async throws {
        let server = Self.server(capabilities: "AUTH=PLAIN SASL-IR", acceptedUser: "archief@icloud.com")
        let session = IMAPSession(transport: server)
        try await session.start()
        try await MailboxProcessor.signIn(session: session, account: IMAPSessionTests.account, password: "abcd-efgh-ijkl-mnop")
        #expect(server.commands.filter { $0.hasPrefix("AUTHENTICATE") }.count == 2)
    }

    @Test func otherServersDontRetry() async throws {
        let server = Self.server(capabilities: "AUTH=PLAIN SASL-IR", acceptedUser: "archief@icloud.com")
        var account = IMAPSessionTests.account
        account.server = "imap.example.com"
        let session = IMAPSession(transport: server)
        try await session.start()
        await #expect(throws: IMAPError.self) {
            try await MailboxProcessor.signIn(session: session, account: account, password: "abcd-efgh-ijkl-mnop")
        }
        #expect(server.commands.filter { $0.hasPrefix("AUTHENTICATE") }.count == 1)
    }
}

@Suite("Mailbox safety")
struct MailboxSafetyTests {
    @Test func refusesInboxOfSharedAccountWithoutConnecting() async throws {
        let server = IMAPSessionTests.server()
        var account = IMAPSessionTests.account
        account.folder = "INBOX"
        await #expect(throws: MailboxError.self) {
            _ = try await MailboxProcessor.run(session: IMAPSession(transport: server), account: account, password: "abcd-efgh-ijkl-mnop") { _ in }
        }
        #expect(server.commands.isEmpty)
        account.accountIsDedicated = true
        #expect(account.validationErrors.isEmpty)
    }

    @Test func missingFolderIsReportedAndNothingIsCreated() async throws {
        let server = IMAPSessionTests.server()
        var account = IMAPSessionTests.account
        account.folder = "Facturen"
        await #expect(throws: MailboxError.folderNotFound("Facturen")) {
            _ = try await MailboxProcessor.run(session: IMAPSession(transport: server), account: account, password: "abcd-efgh-ijkl-mnop") { _ in }
        }
        #expect(!server.commands.contains { $0.hasPrefix("CREATE") })
    }

    @Test func folderRules() {
        var account = IMAPSessionTests.account
        #expect(account.folder == "Paper Trail")
        account.processedFolder = "paper trail"
        #expect(account.validationErrors.count == 1)
        account.processedFolder = "Verwerkt é"
        #expect(account.validationErrors.count == 1)
    }

    @Test func oldSettingsGetSafeFolders() throws {
        let json = Data(#"{"isEnabled":true,"address":"a@icloud.com","username":"a","server":"imap.mail.me.com","port":993,"checkIntervalMinutes":5}"#.utf8)
        let account = try JSONDecoder().decode(MailAccount.self, from: json)
        #expect(account.folder == "Paper Trail")
        #expect(!account.accountIsDedicated)
    }
}

final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []
    func append(_ item: Data) { lock.withLock { storage.append(item) } }
    var items: [Data] { lock.withLock { storage } }
}
