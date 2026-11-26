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

    @Test func extensionComesFromTheLoadedType() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "SharedIncoming-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let image = base.appending(path: "tmp-1.jpeg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: image)
        let folder = SharedIncoming.folder(in: base)
        #expect(try SharedIncoming.save(image, preferredName: "x.pdf", fileExtension: "jpeg", into: folder).lastPathComponent == "x.pdf.jpeg")
        #expect(try SharedIncoming.save(image, preferredName: "Invoice No. 5", fileExtension: "pdf", into: folder).lastPathComponent == "Invoice No. 5.pdf")
        #expect(try SharedIncoming.save(image, preferredName: "Bon.JPEG", fileExtension: "jpeg", into: folder).lastPathComponent == "Bon.JPEG")
    }

    @Test func limitsAndStalePartials() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "SharedIncoming-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let fake = base.appending(path: "fake.pdf")
        try Data("<html>not a pdf</html>".utf8).write(to: fake)
        #expect(throws: SharedIncoming.SaveError.notAPDF("fake.pdf")) { try SharedIncoming.check(fake, isPDF: true) }
        try SharedIncoming.check(fake, isPDF: false)

        let old = base.appending(path: ".abc.partial"), fresh = base.appending(path: ".def.partial")
        try Data().write(to: old)
        try Data().write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-7200)], ofItemAtPath: old.path(percentEncoded: false))
        SharedIncoming.removeStalePartials(in: base)
        #expect(!FileManager.default.fileExists(atPath: old.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: fresh.path(percentEncoded: false)))
    }
}
