import CoreGraphics
import Foundation
import Testing
@testable import PaperTrailKit

/// Till receipts photographed with a phone: two-digit years and VAT tables whose cells the
/// text recogniser returns as separate pieces. Synthetic data only (invented shop, amounts).
@Suite("Receipt layout")
struct ReceiptLayoutTests {
    @Test func twoDigitYears() {
        #expect(TextDates.all(in: "Aangemaakt: 03-08-26, 1:15:00 PM").map(\.date) == ["2026-08-03"])
        #expect(TextDates.all(in: "Bon 5.11.25").map(\.date) == ["2025-11-05"])
        // Four-digit years still win, and amounts, times and phone numbers are no dates.
        #expect(TextDates.all(in: "03-08-2026").map(\.date) == ["2026-08-03"])
        #expect(TextDates.all(in: "€ 12.50  13:45:10  tel 020-12-34-56").isEmpty)
        #expect(TextDates.all(in: "31-02-26").isEmpty)
    }

    @Test func receiptDateFollowsAangemaakt() {
        let text = "Brasserie Proefpand\nAangemaakt: 03-08-26, 1:15:00 PM\nGeprint: 05-08-26, 9:02:11 AM\nTotaal €60.00"
        #expect(TextDates.date(after: ExtractionChecks.documentDateLabels, in: text) == "2026-08-03")
    }

    /// One piece of recognised text; `y` is the height of its centre (0 bottom, 1 top).
    func piece(_ text: String, x: Double, y: Double, height: Double = 0.012) -> RecognizedLine {
        RecognizedLine(text: text, box: CGRect(x: x, y: y - height / 2, width: 0.1, height: height))
    }

    @Test func tableCellsAreJoinedIntoRows() {
        // Returned column by column, as Vision tends to for a wide table; the photo is slightly
        // slanted, so the right-hand cells sit a little higher.
        let pieces = [
            piece("Excl.", x: 0.35, y: 0.300), piece("Btw", x: 0.55, y: 0.301), piece("Incl.", x: 0.8, y: 0.302),
            piece("Btw 0%", x: 0.1, y: 0.280), piece("Btw 9%", x: 0.1, y: 0.260), piece("Btw 21%", x: 0.1, y: 0.240),
            piece("€0.00", x: 0.35, y: 0.281), piece("€40.00", x: 0.35, y: 0.261), piece("€20.00", x: 0.35, y: 0.241),
            piece("€0.00", x: 0.55, y: 0.282), piece("€3.60", x: 0.55, y: 0.262), piece("€4.20", x: 0.55, y: 0.242),
            piece("€0.00", x: 0.8, y: 0.283), piece("€43.60", x: 0.8, y: 0.263), piece("€24.20", x: 0.8, y: 0.243),
            piece("Totaal", x: 0.1, y: 0.40), piece("€67.80", x: 0.8, y: 0.402),
        ]
        let text = RecognizedLine.readingOrderText(pieces)
        #expect(text.components(separatedBy: "\n") == [
            "Totaal  €67.80",
            "Excl.  Btw  Incl.",
            "Btw 0%  €0.00  €0.00  €0.00",
            "Btw 9%  €40.00  €3.60  €43.60",
            "Btw 21%  €20.00  €4.20  €24.20",
        ])

        let vat = VATExtractor.extract(from: text, total: 67.80)
        #expect(vat.lines == [VATLine(rate: 9, base: 40, amount: 3.60), VATLine(rate: 21, base: 20, amount: 4.20)])
        #expect(!vat.isForeign)
    }

    @Test func emptyZeroRateRowIsIgnored() {
        let vat = VATExtractor.extract(from: "Btw 0%  €0.00  €0.00  €0.00\nBtw 21%  €20.00  €4.20  €24.20", total: 24.20)
        #expect(vat.lines == [VATLine(rate: 21, base: 20, amount: 4.20)])
    }
}
