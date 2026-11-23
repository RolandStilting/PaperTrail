import Foundation
import Testing
@testable import PaperTrailKit

@Suite("SharedIncoming")
struct SharedIncomingTests {
    @Test func savesWithUniqueNamesAndKeepsTheExtension() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "SharedIncoming-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appending(path: "tmp-123.pdf")
        try Data("%PDF-1.7 synthetic".utf8).write(to: source)
        let folder = SharedIncoming.folder(in: base)

        let first = try SharedIncoming.save(source, preferredName: "Factuur maart", into: folder)
        let second = try SharedIncoming.save(source, preferredName: "Factuur maart", into: folder)
        let unnamed = try SharedIncoming.save(source, preferredName: nil, into: folder)

        #expect(first.lastPathComponent == "Factuur maart.pdf")
        #expect(second.lastPathComponent == "Factuur maart (2).pdf")
        #expect(unnamed.lastPathComponent == "Shared document.pdf")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).count == 3)
    }
}
