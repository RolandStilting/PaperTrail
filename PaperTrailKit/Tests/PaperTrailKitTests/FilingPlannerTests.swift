import Foundation
import Testing
@testable import PaperTrailKit

@Suite("FilingPlanner")
struct FilingPlannerTests {
    @Test func plansFolderAndName() throws {
        let request = FilingRequest(
            owner: "Private", category: "Invoices", receivedDate: TestSupport.date(2026, 3, 1),
            documentDate: TestSupport.date(2026, 2, 27), sender: "Acme Telecom B.V. Klantenservice", description: "Mobile invoice March"
        )
        let plan = try FilingPlanner.plan(for: request, namer: TestSupport.namer)
        #expect(plan.folderComponents == ["Private", "2026", "Invoices"])
        #expect(plan.relativePath == "Private/2026/Invoices/2026-03-01 Acme Telecom - Mobile invoice March.pdf")
    }

    @Test func yearFollowsReceivedDateNotDocumentDate() throws {
        let request = FilingRequest(
            owner: "Company1", category: "Tax", receivedDate: TestSupport.date(2026, 1, 3),
            documentDate: TestSupport.date(2025, 12, 28), sender: "Tax Office", description: "Assessment"
        )
        #expect(try FilingPlanner.plan(for: request, namer: TestSupport.namer).folderComponents[1] == "2026")
    }

    @Test func rejectsMissingOwnerAndCategory() {
        let base = FilingRequest(owner: "", category: "X", receivedDate: .now, sender: "S", description: "D")
        #expect(throws: FilingError.missingOwner) { try FilingPlanner.plan(for: base) }
        var noCategory = base
        noCategory.owner = "Private"
        noCategory.category = " / "
        #expect(throws: FilingError.missingCategory) { try FilingPlanner.plan(for: noCategory) }
    }

    @Test func rejectsReservedOwner() {
        let request = FilingRequest(owner: "inbox", category: "X", receivedDate: .now, sender: "S", description: "D")
        #expect(throws: FilingError.reservedOwnerName("inbox")) { try FilingPlanner.plan(for: request) }
    }
}

@Suite("FileNameParser")
struct FileNameParserTests {
    @Test func roundTrips() throws {
        let name = TestSupport.namer.fileName(receivedDate: TestSupport.date(2026, 7, 14), sender: "Coca-Cola", description: "Receipt - lunch meeting")
        let parsed = try #require(FileNameParser.parse(name, calendar: TestSupport.calendar))
        #expect(TestSupport.namer.dateString(parsed.receivedDate) == "2026-07-14")
        #expect(parsed.sender == "Coca-Cola")
        #expect(parsed.description == "Receipt - lunch meeting")
        #expect(parsed.duplicateNumber == nil)
    }

    @Test func readsDuplicateNumber() throws {
        let parsed = try #require(FileNameParser.parse("2026-01-02 Shop - Receipt (3).pdf", calendar: TestSupport.calendar))
        #expect(parsed.description == "Receipt")
        #expect(parsed.duplicateNumber == 3)
    }

    @Test(arguments: ["notes.txt", "2026-02-30 Shop - Receipt.pdf", "Shop - Receipt.pdf", "2026-01-02 Shop.pdf"])
    func rejectsOtherNames(name: String) {
        #expect(FileNameParser.parse(name, calendar: TestSupport.calendar) == nil)
    }
}

@Suite("ArchiveSettings")
struct ArchiveSettingsTests {
    @Test func defaultsAreValid() {
        #expect(ArchiveSettings.defaults.validationErrors.isEmpty)
        #expect(ArchiveSettings.defaults.owners.map(\.name) == ["Company1", "Company2", "Private"])
    }

    @Test func flagsDuplicatesEmptyAndReservedNames() {
        let settings = ArchiveSettings(
            owners: [Owner(name: "Private"), Owner(name: "private"), Owner(name: "Needs Review")],
            categories: [DocumentCategory(name: "  ")]
        )
        #expect(settings.validationErrors.count == 3)
    }

    @Test func roundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(ArchiveSettings.defaults)
        #expect(try JSONDecoder().decode(ArchiveSettings.self, from: data) == .defaults)
    }
}
