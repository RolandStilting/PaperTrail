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

    func send(_ data: Data) async throws {
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        let tag = String(line.prefix { $0 != " " })
        let command = String(line.dropFirst(tag.count + 1))
        lock.withLock {
            commands.append(command)
            // Split long responses in two chunks to exercise buffering.
            let response = Data(answer(command).replacingOccurrences(of: "TAG", with: tag).utf8)
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
    static let message = "From: a@example.com\r\nSubject: Bon\r\n\r\nBedrag 12,50\r\n"

    static func server(move: Bool = true, failFetchOf failing: UInt32? = nil) -> ScriptedIMAPServer {
        ScriptedIMAPServer { command in
            switch command {
            case let c where c.hasPrefix("LOGIN"):
                c == #"LOGIN "archief" "abcd-efgh-ijkl-mnop""# ? "TAG OK logged in\r\n" : "TAG NO [AUTHENTICATIONFAILED] Invalid credentials\r\n"
            case "CAPABILITY":
                "* CAPABILITY IMAP4rev1 UIDPLUS\(move ? " MOVE" : "")\r\nTAG OK\r\n"
            case #"CREATE "Processed""#:
                "TAG NO [ALREADYEXISTS] Mailbox exists\r\n"
            case #"LIST "" "Processed""#:
                "* LIST () \"/\" Processed\r\nTAG OK\r\n"
            case #"SELECT "INBOX""#:
                "* 2 EXISTS\r\nTAG OK [READ-WRITE] selected\r\n"
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
        let report = try await MailboxProcessor.run(session: IMAPSession(transport: server), user: "archief", password: "abcd-efgh-ijkl-mnop") { raw in
            received.append(raw)
        }
        #expect(report == MailboxReport(processed: 2))
        #expect(received.items.map { String(decoding: $0, as: UTF8.self) } == [Self.message, Self.message])
        #expect(server.commands.contains(#"UID MOVE 7 "Processed""#))
        #expect(server.commands.contains(#"UID MOVE 9 "Processed""#))
        #expect(server.commands.last == "LOGOUT")
    }

    @Test func withoutMoveCopiesFlagsAndExpunges() async throws {
        let server = Self.server(move: false)
        _ = try await MailboxProcessor.run(session: IMAPSession(transport: server), user: "archief", password: "abcd-efgh-ijkl-mnop") { _ in }
        #expect(server.commands.contains(#"UID COPY 7 "Processed""#))
        #expect(server.commands.contains(#"UID STORE 7 +FLAGS.SILENT (\Deleted)"#))
        #expect(server.commands.contains("UID EXPUNGE 7"))
    }

    @Test func failedEmailStaysInInbox() async throws {
        let server = Self.server(failFetchOf: 9)
        let report = try await MailboxProcessor.run(session: IMAPSession(transport: server), user: "archief", password: "abcd-efgh-ijkl-mnop") { _ in }
        #expect(report.processed == 1)
        #expect(report.failures.count == 1)
        #expect(!server.commands.contains(#"UID MOVE 9 "Processed""#))
    }

    @Test func handlerFailureKeepsEmail() async throws {
        let server = Self.server()
        struct Boom: Error {}
        let report = try await MailboxProcessor.run(session: IMAPSession(transport: server), user: "archief", password: "abcd-efgh-ijkl-mnop") { _ in throw Boom() }
        #expect(report.processed == 0)
        #expect(!server.commands.contains { $0.hasPrefix("UID MOVE") })
    }

    @Test func wrongPasswordIsALoginErrorWithoutThePassword() async throws {
        let server = Self.server()
        do {
            _ = try await MailboxProcessor.run(session: IMAPSession(transport: server), user: "archief", password: "wrong-secret") { _ in }
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

final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []
    func append(_ item: Data) { lock.withLock { storage.append(item) } }
    var items: [Data] { lock.withLock { storage } }
}
