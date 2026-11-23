import Foundation
import Testing
@testable import PaperTrailKit

@Suite("SEPACreditTransfer")
struct SEPACreditTransferTests {
    static let calendar = TestSupport.calendar
    static let moment = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 14, minute: 32, second: 5))!
    // Public example IBANs from IBAN documentation, not real accounts of anyone involved.
    static let debtor = PayingAccount(name: "Voorbeeld Holding B.V.", iban: "NL91ABNA0417164300")

    static func payments() -> [SEPAPayment] {
        [
            SEPAPayment(creditorName: "Gemeente Fictiedam", creditorIBAN: "DE89370400440532013000", amount: 812.4,
                        reference: "5123 4567 8901 2345", endToEndID: "PT-1"),
            SEPAPayment(creditorName: "Café & Co <Test>", creditorIBAN: "NL91 ABNA 0417 1643 00", amount: 45.99,
                        reference: "Factuur BD-778812", endToEndID: "PT-2"),
        ]
    }

    static func xml() throws -> String {
        try SEPACreditTransfer.xml(messageID: "PT-20261123-1432", created: moment, executionDate: moment,
                                   debtor: debtor, payments: payments(), calendar: calendar)
    }

    @Test func headerTotalsAndDates() throws {
        let xml = try Self.xml()
        #expect(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:pain.001.001.03\""))
        #expect(xml.components(separatedBy: "<NbOfTxs>2</NbOfTxs>").count == 3)
        #expect(xml.components(separatedBy: "<CtrlSum>858.39</CtrlSum>").count == 3)
        #expect(xml.contains("<CreDtTm>2026-11-23T14:32:05</CreDtTm>"))
        #expect(xml.contains("<ReqdExctnDt>2026-11-23</ReqdExctnDt>"))
        #expect(xml.contains("<Id>NOTPROVIDED</Id>"))
        #expect(xml.contains("<InstdAmt Ccy=\"EUR\">812.40</InstdAmt>"))
    }

    @Test func referencesAndNames() throws {
        let xml = try Self.xml()
        #expect(xml.contains("<Issr>CUR</Issr>"))
        #expect(xml.contains("<Ref>5123456789012345</Ref>"))
        #expect(xml.contains("<Ustrd>Factuur BD-778812</Ustrd>"))
        // "é" loses its accent, "&", "<" and ">" are outside the SEPA character set.
        #expect(xml.contains("<Nm>Cafe Co Test</Nm>"))
    }

    @Test func isWellFormedXML() throws {
        let parser = XMLParser(data: Data(try Self.xml().utf8))
        #expect(parser.parse())
    }

    @Test func rejectsUnusableBatches() {
        var bad = Self.payments()
        bad[1].creditorIBAN = "NL00TEST0123456789"
        #expect(throws: SEPACreditTransfer.ValidationError.invalidCreditorIBAN("PT-2")) {
            try SEPACreditTransfer.xml(messageID: "x", created: Self.moment, executionDate: Self.moment, debtor: Self.debtor, payments: bad)
        }
        #expect(throws: SEPACreditTransfer.ValidationError.missingDebtor) {
            try SEPACreditTransfer.xml(messageID: "x", created: Self.moment, executionDate: Self.moment, debtor: PayingAccount(), payments: Self.payments())
        }
        #expect(throws: SEPACreditTransfer.ValidationError.noPayments) {
            try SEPACreditTransfer.xml(messageID: "x", created: Self.moment, executionDate: Self.moment, debtor: Self.debtor, payments: [])
        }
    }
}
