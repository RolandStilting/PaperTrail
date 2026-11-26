import Foundation
import Testing
@testable import PaperTrailKit

/// A stateful IMAP server with UIDPLUS and MOVE: mailboxes hold UIDs, moves answer with
/// COPYUID, and a move of a UID that's gone moves nothing (as real servers do).
final class MailboxServer: @unchecked Sendable {
    let lock = NSLock()
    var boxes: [String: [UInt32]] = ["Paper Trail": [7, 9], "Paper Trail Processed": [], "Paper Trail Working": []]
    var nextUID: UInt32 = 100
    var selected = ""
    /// Called before a move, e.g. to let "another device" take the email first.
    var beforeMove: ((UInt32) -> Void)?

    lazy var transport = ScriptedIMAPServer { [unowned self] command in self.answer(command) }

    func answer(_ command: String) -> String {
        lock.withLock {
            func name(_ text: Substring) -> String { String(text).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            switch command {
            case let c where c.hasPrefix("LOGIN"): return "TAG OK\r\n"
            case "CAPABILITY": return "* CAPABILITY IMAP4rev1 UIDPLUS MOVE\r\nTAG OK\r\n"
            case let c where c.hasPrefix("CREATE"): return "TAG NO [ALREADYEXISTS]\r\n"
            case let c where c.hasPrefix("LIST"): return "* LIST () \"/\" x\r\nTAG OK\r\n"
            case let c where c.hasPrefix("SELECT "):
                selected = name(c.dropFirst("SELECT ".count))
                return "TAG OK\r\n"
            case "UID SEARCH ALL":
                return "* SEARCH \((boxes[selected] ?? []).map(String.init).joined(separator: " "))\r\nTAG OK\r\n"
            case let c where c.hasPrefix("UID FETCH"):
                let message = "Subject: Bon\r\n\r\nBedrag 12,50\r\n"
                return "* 1 FETCH (BODY[] {\(message.utf8.count)}\r\n\(message))\r\nTAG OK\r\n"
            case let c where c.hasPrefix("UID MOVE "):
                let parts = c.dropFirst("UID MOVE ".count).split(separator: " ", maxSplits: 1)
                let uid = UInt32(parts[0])!
                let target = name(parts[1])
                lock.unlock(); beforeMove?(uid); lock.lock()
                guard let index = boxes[selected]?.firstIndex(of: uid) else { return "TAG OK no messages\r\n" }
                boxes[selected]!.remove(at: index)
                nextUID += 1
                boxes[target, default: []].append(nextUID)
                return "* OK [COPYUID 1 \(uid) \(nextUID)]\r\n* 1 EXPUNGE\r\nTAG OK done\r\n"
            default: return "TAG OK\r\n"
            }
        }
    }
}

@Suite("Mail claims")
struct MailClaimTests {
    static let account = MailAccount(isEnabled: true, address: "archief@icloud.example", username: "archief")

    @Test func claimsThenFilesEachEmail() async throws {
        let server = MailboxServer()
        let report = try await MailboxProcessor.run(session: IMAPSession(transport: server.transport), account: Self.account,
                                                    password: "abcd-efgh-ijkl-mnop", requireClaims: true) { _ in }
        #expect(report.processed == 2)
        #expect(server.boxes["Paper Trail"] == [])
        #expect(server.boxes["Paper Trail Working"] == [])
        #expect(server.boxes["Paper Trail Processed"]?.count == 2)
        #expect(server.transport.commands.contains(#"UID MOVE 7 "Paper Trail Working""#))
        #expect(report.workingSeen.isEmpty)
    }

    @Test func emailTakenByAnotherDeviceIsSkipped() async throws {
        let server = MailboxServer()
        // Another device moves UID 9 to Working just before this one tries.
        server.beforeMove = { uid in
            guard uid == 9 else { return }
            server.lock.withLock {
                if let index = server.boxes["Paper Trail"]?.firstIndex(of: 9) {
                    server.boxes["Paper Trail"]!.remove(at: index)
                    server.boxes["Paper Trail Working"]!.append(500)
                }
            }
        }
        let handled = LockedList()
        let report = try await MailboxProcessor.run(session: IMAPSession(transport: server.transport), account: Self.account,
                                                    password: "abcd-efgh-ijkl-mnop") { raw in handled.append(raw) }
        #expect(report.processed == 1)
        #expect(report.claimedElsewhere == 1)
        #expect(handled.items.count == 1)
    }

    @Test func failedEmailGoesBackAndIsHandledLast() async throws {
        let server = MailboxServer()
        struct Boom: Error {}
        let report = try await MailboxProcessor.run(session: IMAPSession(transport: server.transport), account: Self.account,
                                                    password: "abcd-efgh-ijkl-mnop") { _ in throw Boom() }
        #expect(report.processed == 0)
        #expect(server.boxes["Paper Trail"]?.count == 2)
        #expect(server.boxes["Paper Trail Working"] == [])
        #expect(report.failedUIDs == Set(server.boxes["Paper Trail"]!))
    }

    @Test func abandonedClaimGoesBackAfterAnHour() async throws {
        let server = MailboxServer()
        server.boxes["Paper Trail"] = []
        server.boxes["Paper Trail Working"] = [40, 41]
        let now = Date(timeIntervalSince1970: 1_795_600_000)
        // First pass: 40 was seen an hour ago, 41 is new.
        let report = try await MailboxProcessor.run(session: IMAPSession(transport: server.transport), account: Self.account,
                                                    password: "abcd-efgh-ijkl-mnop", workingSeenBefore: [40: now.addingTimeInterval(-3_700)],
                                                    now: now) { _ in }
        #expect(server.transport.commands.contains(#"UID MOVE 40 "Paper Trail""#))
        #expect(!server.transport.commands.contains(#"UID MOVE 41 "Paper Trail""#))
        #expect(report.workingSeen[41] == now)
        #expect(report.processed == 1)  // 40 came back and was filed in the same pass
    }

    @Test func refusesWithoutClaimsWhenRequired() async throws {
        let server = IMAPSessionTests.server()
        await #expect(throws: MailboxError.claimsUnsupported) {
            _ = try await MailboxProcessor.run(session: IMAPSession(transport: server), account: Self.account,
                                               password: "abcd-efgh-ijkl-mnop", requireClaims: true) { _ in }
        }
    }

    @Test func readsCopyUID() {
        #expect(IMAPSession.copiedUID(in: ["* OK [COPYUID 1617 7 104] Moved"]) == 104)
        #expect(IMAPSession.copiedUID(in: ["OK [copyuid 1617 7 104] done"]) == 104)
        #expect(IMAPSession.copiedUID(in: ["OK no messages"]) == nil)
    }
}
