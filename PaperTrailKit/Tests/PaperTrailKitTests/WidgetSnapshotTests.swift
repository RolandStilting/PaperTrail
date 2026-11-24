import Foundation
import Testing
@testable import PaperTrailKit

/// Synthetic bills only.
@Suite("WidgetSnapshot")
struct WidgetSnapshotTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }()
    func date(_ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 12))! }

    var bills: [WidgetSnapshot.Bill] {
        [.init(id: UUID(), sender: "Later BV", owner: "Company1", amount: 853.66, dueDate: date(28)),
         .init(id: UUID(), sender: "Voorbeeld Energie", owner: "Private", amount: 142.37, dueDate: date(21)),
         .init(id: UUID(), sender: "Geen Datum", owner: "Private", amount: nil, dueDate: nil)]
    }

    @Test func summarisesAndSortsByDueDate() {
        let snapshot = WidgetSnapshot.make(openBills: bills, expenseAmounts: [12.10, 17.90], reviewCount: 3, hidesDetails: false,
                                           now: date(24), calendar: calendar)
        #expect(snapshot.openBillCount == 3)
        #expect(snapshot.openBillTotal == 996.03)
        #expect(snapshot.overdueCount == 1)
        #expect(snapshot.expenseTotal == 30)
        #expect(snapshot.bills.map(\.sender) == ["Voorbeeld Energie", "Later BV", "Geen Datum"])
    }

    @Test func lockedHidesAmountsAndSenders() {
        let snapshot = WidgetSnapshot.make(openBills: bills, expenseAmounts: [12.10], reviewCount: 0, hidesDetails: true,
                                           now: date(24), calendar: calendar)
        #expect(snapshot.openBillCount == 3 && snapshot.overdueCount == 1)
        #expect(snapshot.openBillTotal == nil && snapshot.expenseTotal == nil)
        #expect(snapshot.bills.isEmpty)
    }

    @Test func overdueFollowsTheDay() {
        let snapshot = WidgetSnapshot.make(openBills: bills, expenseAmounts: [], reviewCount: 0, hidesDetails: false,
                                           now: date(24), calendar: calendar)
        #expect(snapshot.overdue(today: date(30), calendar: calendar) == 2)
    }

    @Test func writesAndReadsBack() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "WidgetSnapshot-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let snapshot = WidgetSnapshot.sample(now: Date(timeIntervalSince1970: 1_800_000_000))
        try snapshot.write(to: folder)
        #expect(WidgetSnapshot.read(from: folder) == snapshot)
        #expect(WidgetSnapshot.read(from: folder.appending(path: "missing")) == nil)
    }
}
