import Foundation
import Testing
@testable import PaperTrail

/// Guards against the NSUbiquitousContainers key in project.yml drifting from the bundle ID.
@Suite("iCloud container configuration")
struct ICloudContainerConfigTests {
    @Test func containerMatchesBundleIdentifier() throws {
        let bundleID = try #require(Bundle.main.bundleIdentifier)
        #expect(ICloudArchiveLocation.containerIdentifier == "iCloud.\(bundleID)")
    }

    @Test func iCloudDriveFolderIsDeclaredForTheContainer() throws {
        let containers = try #require(Bundle.main.object(forInfoDictionaryKey: "NSUbiquitousContainers") as? [String: Any])
        let identifier = try #require(ICloudArchiveLocation.containerIdentifier)
        #expect(containers[identifier] != nil, "Update the NSUbiquitousContainers key in project.yml to \(identifier)")
    }
}
