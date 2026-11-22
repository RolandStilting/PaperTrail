import Foundation
import Testing
@testable import PaperTrailKit

@Suite("FileNamer")
struct FileNamerTests {
    let namer = TestSupport.namer

    @Test func buildsNameFromParts() {
        let name = namer.fileName(receivedDate: TestSupport.date(2026, 3, 1), sender: "Acme Energy", description: "Electricity invoice March")
        #expect(name == "2026-03-01 Acme Energy - Electricity invoice March.pdf")
    }

    @Test func usesReceivedDayInCalendarTimeZone() {
        // 23:30 UTC on 31 Dec is already 1 Jan in Amsterdam.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = utc.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 23, minute: 30))!
        #expect(namer.dateString(date) == "2026-01-01")
        #expect(namer.year(of: date) == 2026)
    }

    @Test(arguments: [
        ("Invoice 2026/03", "Invoice 2026 03"),
        ("What? \"Really\" <yes> | no", "What Really yes no"),
        ("a:b\\c*d", "a b c d"),
        ("  lots   of\tspace\n", "lots of space"),
        ("...hidden", "hidden"),
        ("trailing dots...", "trailing dots"),
    ])
    func sanitizesComponents(input: String, expected: String) {
        #expect(FileNamer.sanitizeComponent(input) == expected)
    }

    @Test func limitsDescriptionToSixWords() {
        #expect(namer.cleanDescription("one two three four five six seven eight") == "one two three four five six")
    }

    @Test func fallsBackWhenPartsAreEmpty() {
        let name = namer.fileName(receivedDate: TestSupport.date(2026, 5, 9), sender: " / ", description: "??")
        #expect(name == "2026-05-09 Unknown - Document.pdf")
    }

    @Test func removesSeparatorFromSender() {
        #expect(namer.cleanSender("Alpha - Beta") == "Alpha Beta")
    }

    @Test func limitsSenderLength() {
        let long = String(repeating: "x", count: 60)
        #expect(namer.cleanSender(long).count == 40)
    }
}

@Suite("SenderNormalizer")
struct SenderNormalizerTests {
    @Test(arguments: [
        ("Acme Telecom B.V. Klantenservice", "Acme Telecom"),
        ("Fictional Bank N.V.", "Fictional Bank"),
        ("Example GmbH", "Example"),
        ("Sample Widgets Ltd.", "Sample Widgets"),
        ("Demo Corp, Inc.", "Demo Corp"),
        ("Gemeente Voorbeeldstad", "Gemeente Voorbeeldstad"),
        ("BV Testbedrijf", "BV Testbedrijf"),
        ("", ""),
    ])
    func normalizes(input: String, expected: String) {
        #expect(SenderNormalizer.normalize(input) == expected)
    }
}

@Suite("Collisions")
struct CollisionTests {
    @Test func returnsOriginalWhenFree() {
        #expect(FileNamer.uniqueFileName("a.pdf") { _ in false } == "a.pdf")
    }

    @Test func appendsNumbersStartingAtTwo() {
        let taken: Set = ["a.pdf", "a (2).pdf", "a (3).pdf"]
        #expect(FileNamer.uniqueFileName("a.pdf") { taken.contains($0) } == "a (4).pdf")
    }

    @Test func callerControlsCaseInsensitivity() {
        let taken: Set = ["report.pdf"]
        #expect(FileNamer.uniqueFileName("Report.pdf") { taken.contains($0.lowercased()) } == "Report (2).pdf")
    }

    @Test func givesUpAfterMaxAttempts() {
        #expect(FileNamer.uniqueFileName("a.pdf", maxAttempts: 5) { _ in true } == nil)
    }
}
