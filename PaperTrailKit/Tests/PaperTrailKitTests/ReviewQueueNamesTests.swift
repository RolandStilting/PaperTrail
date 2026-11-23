import Foundation
import Testing
@testable import PaperTrailKit

@Suite("ReviewQueueNames")
struct ReviewQueueNamesTests {
    static let calendar = TestSupport.calendar
    static let moment = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 14, minute: 32))!

    @Test func namesScansAndImports() {
        #expect(ReviewQueueNames.fileName(savedAt: Self.moment, originalName: nil, calendar: Self.calendar) == "2026-11-23 1432 Scan.pdf")
        #expect(ReviewQueueNames.fileName(savedAt: Self.moment, originalName: "factuur: maart?.PDF", calendar: Self.calendar) == "2026-11-23 1432 factuur maart.pdf")
    }

    @Test func readsDirectoryEntries() {
        #expect(ReviewQueueNames.itemName(forDirectoryEntry: "2026-11-23 1432 Scan.pdf") == "2026-11-23 1432 Scan.pdf")
        #expect(ReviewQueueNames.itemName(forDirectoryEntry: ".2026-11-23 1432 Scan.pdf.icloud") == "2026-11-23 1432 Scan.pdf")
        #expect(ReviewQueueNames.itemName(forDirectoryEntry: ".DS_Store") == nil)
        #expect(ReviewQueueNames.itemName(forDirectoryEntry: "notes.txt") == nil)
    }

    @Test func readsSavedDate() throws {
        let date = try #require(ReviewQueueNames.savedDate(fromFileName: "2026-11-23 1432 Scan.pdf", calendar: Self.calendar))
        #expect(Self.calendar.component(.day, from: date) == 23)
        #expect(ReviewQueueNames.savedDate(fromFileName: "Scan.pdf", calendar: Self.calendar) == nil)
        #expect(ReviewQueueNames.savedDate(fromFileName: "2026-02-30 Scan.pdf", calendar: Self.calendar) == nil)
    }
}
