import Foundation
import Testing
@testable import PaperTrailKit

@Suite("IBAN")
struct IBANTests {
    // Public example IBANs from the IBAN registry documentation.
    @Test func validatesChecksum() {
        #expect(IBAN.isValid("NL91 ABNA 0417 1643 00"))
        #expect(IBAN.isValid("de89370400440532013000"))
        #expect(!IBAN.isValid("NL91 ABNA 0417 1643 01"))
        #expect(!IBAN.isValid("NL00TEST0123456789"))
        #expect(!IBAN.isValid("123"))
    }

    @Test func formatsInGroupsOfFour() {
        #expect(IBAN.formatted("nl91abna0417164300") == "NL91 ABNA 0417 1643 00")
    }
}

@Suite("BillReminderText")
struct BillReminderTextTests {
    static let dutch = Locale(identifier: "nl_NL")

    @Test func titleAndList() {
        #expect(BillReminderText.listName(owner: "Company1") == "To pay – Company1")
        let title = BillReminderText.title(sender: "Praatnet", amount: 45.99, locale: Self.dutch)
        #expect(title.hasPrefix("Pay Praatnet · €"))
        #expect(title.hasSuffix("45,99"))
        #expect(BillReminderText.title(sender: "Praatnet", amount: nil) == "Pay Praatnet")
    }

    @Test func notesListPaymentDetails() {
        let notes = BillReminderText.notes(amount: 45.99, iban: "NL91ABNA0417164300", reference: "BD-778812",
                                           relativePath: "Private/2026/Invoices/2026-02-20 Praatnet - Herinnering.pdf", locale: Self.dutch)
        let lines = notes.split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines[1] == "IBAN: NL91 ABNA 0417 1643 00")
        #expect(lines[2] == "Reference: BD-778812")
        #expect(lines[3] == "Document: Paper Trail/Private/2026/Invoices/2026-02-20 Praatnet - Herinnering.pdf")
    }
}

@Suite("EPCQRCode")
struct EPCQRCodeTests {
    @Test func buildsPayloadWithFreeTextReference() throws {
        let payload = try EPCQRCode.payload(name: "Praatnet Demo", iban: "NL91 ABNA 0417 1643 00", amount: 45.99, reference: "BD-778812")
        #expect(payload == "BCD\n002\n1\nSCT\n\nPraatnet Demo\nNL91ABNA0417164300\nEUR45.99\n\n\nBD-778812")
    }

    @Test func creditorReferenceGoesInStructuredField() throws {
        let payload = try EPCQRCode.payload(name: "Example", iban: "NL91ABNA0417164300", amount: 10, reference: "RF18 5390 0754 7034")
        #expect(payload.hasSuffix("EUR10.00\n\nRF18539007547034"))
    }

    @Test func rejectsBadInput() {
        #expect(throws: EPCQRCode.PayloadError.invalidIBAN) { try EPCQRCode.payload(name: "A", iban: "NL00TEST0123456789", amount: 1) }
        #expect(throws: EPCQRCode.PayloadError.missingName) { try EPCQRCode.payload(name: " ", iban: "NL91ABNA0417164300", amount: 1) }
        #expect(throws: EPCQRCode.PayloadError.amountOutOfRange) { try EPCQRCode.payload(name: "A", iban: "NL91ABNA0417164300", amount: 0) }
    }
}

@Suite("Owner payment settings")
struct OwnerPaymentTests {
    @Test func oldSettingsDecodeWithDefaults() throws {
        let json = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Private"}"#.utf8)
        let owner = try JSONDecoder().decode(Owner.self, from: json)
        #expect(owner.paymentMethod == .qrCode)
        #expect(owner.payingAccount.isEmpty)
    }

    @Test func sepaOwnerNeedsAccount() {
        var settings = ArchiveSettings.defaults
        settings.owners[0].paymentMethod = .sepaFile
        #expect(settings.validationErrors.count == 1)
        settings.owners[0].payingAccount = PayingAccount(name: "Company1 B.V.", iban: "NL91ABNA0417164300")
        #expect(settings.validationErrors.isEmpty)
        settings.owners[0].payingAccount.iban = "NL91ABNA0417164301"
        #expect(settings.validationErrors.count == 1)
    }
}

@Suite("Owner colours")
struct OwnerColorTests {
    @Test func automaticByPositionUnlessChosen() {
        var settings = ArchiveSettings.defaults
        #expect(settings.color(ofOwner: "Company1") == .blue)
        #expect(settings.color(ofOwner: "Company2") == .teal)
        settings.owners[0].color = .purple
        #expect(settings.color(ofOwner: "Company1") == .purple)
        #expect(settings.color(ofOwner: "Unknown") == .gray)
    }
}
