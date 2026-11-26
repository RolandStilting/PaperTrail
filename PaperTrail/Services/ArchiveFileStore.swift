import CryptoKit
import Foundation
import PaperTrailKit

nonisolated struct StoredFile: Sendable, Equatable {
    var url: URL
    var relativePath: String
    /// SHA-256 of the written bytes, hex encoded.
    var contentHash: String
    /// Why the source could not be removed after the document was safely written. The
    /// document is filed; the source (e.g. in Needs Review) is still there and should be
    /// deleted by hand. nil when it was removed, or was already gone.
    var sourceNotRemoved: String? = nil
}

nonisolated protocol ArchiveFileStoring: Sendable {
    /// Writes `pdf` to the planned location (adding ` (2)`, ` (3)` on collision), verifies it,
    /// and only then removes `sourceToRemove` if given. Once the document is written, a source
    /// that can't be removed doesn't make it fail (see `StoredFile.sourceNotRemoved`): throwing
    /// then would leave a filed document without a record, and trying again would file it twice.
    func store(_ pdf: Data, plan: FilingPlan, root: URL, removingSource sourceToRemove: URL?) async throws -> StoredFile
    /// Moves a filed document to the planned location (adding ` (2)`, ` (3)` on collision) and
    /// returns its new path relative to `root`. A move never copies, so the file can't be lost.
    func move(_ relativePath: String, to plan: FilingPlan, root: URL) async throws -> String
}

nonisolated enum ArchiveFileStoreError: LocalizedError {
    case tooManyCollisions(String)
    case verificationFailed(String)
    case writeFailed(String, underlying: String)
    case fileMissing(String)

    var errorDescription: String? {
        switch self {
        case .tooManyCollisions(let name):
            String(localized: "Could not find a free file name for \"\(name)\". Change the description and try again.")
        case .verificationFailed(let name):
            String(localized: "\"\(name)\" was written but could not be verified. The document was not removed from its source. Check iCloud Drive and try again.")
        case .writeFailed(let name, let underlying):
            String(localized: "Could not save \"\(name)\": \(underlying). Check that iCloud Drive has free space and try again.")
        case .fileMissing(let name):
            String(localized: "\"\(name)\" is no longer where Paper Trail filed it. It may have been moved or renamed on another device; wait for iCloud Drive to catch up and try again.")
        }
    }
}

/// Writes files with `NSFileCoordinator`, as required for iCloud Drive.
nonisolated struct CoordinatedFileStore: ArchiveFileStoring {
    @concurrent
    func store(_ pdf: Data, plan: FilingPlan, root: URL, removingSource sourceToRemove: URL?) async throws -> StoredFile {
        let fileManager = FileManager.default
        let folder = plan.folderComponents.reduce(root) { $0.appending(path: $1, directoryHint: .isDirectory) }

        // 1. Stage the bytes outside the archive so a half-written file never appears in iCloud Drive.
        let staging = fileManager.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
        try pdf.write(to: staging, options: .atomic)
        defer { try? fileManager.removeItem(at: staging) }

        // 2. Create the folder and move the file in under coordination. moveItem never
        //    overwrites, so a name taken by another device in the meantime just moves on to the next number.
        let destination = try coordinatedMove(from: staging, into: folder, preferredName: plan.fileName)

        // 3. Verify what landed on disk before touching the source.
        let expectedHash = Self.sha256(pdf)
        let written = try coordinatedRead(destination)
        guard Self.sha256(written) == expectedHash else {
            throw ArchiveFileStoreError.verificationFailed(destination.lastPathComponent)
        }

        // 4. Only now remove the source (e.g. from Inbox). Gone already is fine.
        var sourceNotRemoved: String?
        if let sourceToRemove {
            do {
                try coordinatedDelete(sourceToRemove)
            } catch {
                if fileManager.fileExists(atPath: sourceToRemove.path(percentEncoded: false)) {
                    sourceNotRemoved = error.localizedDescription
                }
            }
        }

        let relativePath = ArchivePaths.relativePath(components: plan.folderComponents, fileName: destination.lastPathComponent)
        return StoredFile(url: destination, relativePath: relativePath, contentHash: expectedHash, sourceNotRemoved: sourceNotRemoved)
    }

    @concurrent
    func move(_ relativePath: String, to plan: FilingPlan, root: URL) async throws -> String {
        let fileManager = FileManager.default
        let source = root.appending(path: relativePath, directoryHint: .notDirectory)
        let sourceName = source.lastPathComponent
        guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else {
            throw ArchiveFileStoreError.fileMissing(sourceName)
        }
        let folder = plan.folderComponents.reduce(root) { $0.appending(path: $1, directoryHint: .isDirectory) }
        let sameFolder = folder.standardizedFileURL.path(percentEncoded: false).lowercased()
            == source.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false).lowercased()

        var result: Result<URL, Error> = .failure(ArchiveFileStoreError.tooManyCollisions(plan.fileName))
        var coordinationError: NSError?
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ArchiveFileStoreError.writeFailed(plan.fileName, underlying: error.localizedDescription)
        }
        var taken = Set(((try? fileManager.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []).map { $0.lowercased() })
        // Renaming within its folder (e.g. only the case of a letter): its own name is free.
        if sameFolder { taken.remove(sourceName.lowercased()) }
        while let name = FileNamer.uniqueFileName(plan.fileName, exists: { taken.contains($0.lowercased()) }) {
            let target = folder.appending(path: name, directoryHint: .notDirectory)
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var collided = false
            coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: target, options: .forReplacing, error: &coordinationError) { from, to in
                do {
                    try fileManager.moveItem(at: from, to: to)
                    coordinator.item(at: from, didMoveTo: to)
                    result = .success(to)
                } catch CocoaError.fileWriteFileExists {
                    collided = true
                } catch {
                    result = .failure(ArchiveFileStoreError.writeFailed(name, underlying: error.localizedDescription))
                }
            }
            if let coordinationError {
                throw ArchiveFileStoreError.writeFailed(name, underlying: coordinationError.localizedDescription)
            }
            guard collided else { break }
            taken.insert(name.lowercased())
        }
        let moved = try result.get()
        guard fileManager.fileExists(atPath: moved.path(percentEncoded: false)) else {
            throw ArchiveFileStoreError.verificationFailed(moved.lastPathComponent)
        }
        return ArchivePaths.relativePath(components: plan.folderComponents, fileName: moved.lastPathComponent)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func coordinatedMove(from staging: URL, into folder: URL, preferredName: String) throws -> URL {
        let fileManager = FileManager.default
        var result: Result<URL, Error> = .failure(ArchiveFileStoreError.tooManyCollisions(preferredName))
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: folder, options: .forMerging, error: &coordinationError) { folderURL in
            do {
                try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
                let existing = Set(((try? fileManager.contentsOfDirectory(atPath: folderURL.path(percentEncoded: false))) ?? []).map { $0.lowercased() })
                var taken = existing
                while let name = FileNamer.uniqueFileName(preferredName, exists: { taken.contains($0.lowercased()) }) {
                    let target = folderURL.appending(path: name, directoryHint: .notDirectory)
                    do {
                        try fileManager.moveItem(at: staging, to: target)
                        result = .success(target)
                        return
                    } catch CocoaError.fileWriteFileExists {
                        taken.insert(name.lowercased())
                    }
                }
            } catch {
                result = .failure(ArchiveFileStoreError.writeFailed(preferredName, underlying: error.localizedDescription))
            }
        }
        if let coordinationError {
            throw ArchiveFileStoreError.writeFailed(preferredName, underlying: coordinationError.localizedDescription)
        }
        return try result.get()
    }

    private func coordinatedRead(_ url: URL) throws -> Data {
        var result: Result<Data, Error> = .failure(ArchiveFileStoreError.verificationFailed(url.lastPathComponent))
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result { try Data(contentsOf: readURL) }
        }
        if coordinationError != nil { throw ArchiveFileStoreError.verificationFailed(url.lastPathComponent) }
        return try result.get()
    }

    private func coordinatedDelete(_ url: URL) throws {
        var result: Result<Void, Error> = .success(())
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { deleteURL in
            result = Result { try FileManager.default.removeItem(at: deleteURL) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }
}
