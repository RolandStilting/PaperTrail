import Foundation
import PaperTrailKit
import Testing
@testable import PaperTrail

@Suite("CoordinatedFileStore")
struct CoordinatedFileStoreTests {
    let root: URL
    let plan = FilingPlan(folderComponents: ["Private", "2026", "Receipts"], fileName: "2026-04-02 Test Shop - Receipt.pdf")
    let pdf = Data("%PDF-1.7 synthetic test bytes".utf8)

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "PaperTrailTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @Test func writesIntoPlannedFolder() async throws {
        let stored = try await CoordinatedFileStore().store(pdf, plan: plan, root: root, removingSource: nil)
        #expect(stored.relativePath == "Private/2026/Receipts/2026-04-02 Test Shop - Receipt.pdf")
        #expect(try Data(contentsOf: stored.url) == pdf)
        #expect(stored.contentHash == CoordinatedFileStore.sha256(pdf))
    }

    @Test func appendsNumberOnCollision() async throws {
        let store = CoordinatedFileStore()
        _ = try await store.store(pdf, plan: plan, root: root, removingSource: nil)
        let second = try await store.store(pdf, plan: plan, root: root, removingSource: nil)
        let third = try await store.store(pdf, plan: plan, root: root, removingSource: nil)
        #expect(second.url.lastPathComponent == "2026-04-02 Test Shop - Receipt (2).pdf")
        #expect(third.url.lastPathComponent == "2026-04-02 Test Shop - Receipt (3).pdf")
    }

    @Test func removesSourceOnlyAfterWriting() async throws {
        let inbox = root.appending(path: ArchivePaths.inboxFolderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let source = inbox.appending(path: "scan.pdf")
        try pdf.write(to: source)

        let stored = try await CoordinatedFileStore().store(pdf, plan: plan, root: root, removingSource: source)
        #expect(FileManager.default.fileExists(atPath: stored.url.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
    }

    /// Filed on another device at the same time: the source is gone, but this copy is written,
    /// so it must not fail (that would leave a file without a record).
    @Test func missingSourceAfterWritingIsNoError() async throws {
        let source = root.appending(path: "Needs Review/gone.pdf")
        let stored = try await CoordinatedFileStore().store(pdf, plan: plan, root: root, removingSource: source)
        #expect(stored.sourceNotRemoved == nil)
        #expect(FileManager.default.fileExists(atPath: stored.url.path(percentEncoded: false)))
    }

    @Test func temporaryExportsAreCleanedUp() throws {
        let temp = root.appending(path: "tmp", directoryHint: .isDirectory)
        let claim = temp.appending(path: "\(TemporaryFiles.claimsFolder)/x/claim.pdf")
        try FileManager.default.createDirectory(at: claim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf.write(to: claim)
        let staged = temp.appending(path: "\(UUID().uuidString).pdf")
        let other = temp.appending(path: "keep.pdf")
        try pdf.write(to: staged)
        try pdf.write(to: other)
        TemporaryFiles.cleanUp(in: temp, now: .now.addingTimeInterval(7200))
        #expect(!FileManager.default.fileExists(atPath: claim.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: other.path(percentEncoded: false)))
    }
}
