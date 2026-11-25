import Foundation
import Testing
@testable import PaperTrailKit

/// Synthetic data only (invented companies and codes).
@Suite("LedgerCodes")
struct LedgerCodeTests {
    static let invoices = DocumentCategory(name: "Invoices", usesLedgerCodes: true)
    static let receipts = DocumentCategory(name: "Receipts", usesLedgerCodes: true)
    static let letters = DocumentCategory(name: "Letters")
    static let codes = [
        LedgerCode(code: "4300", description: "Telefoon en internet"),
        LedgerCode(code: "4510", description: "Kantoorbenodigdheden"),
        LedgerCode(code: "4600", description: "Reiskosten"),
    ]

    static var settings: ArchiveSettings {
        ArchiveSettings(owners: [Owner(name: "Company1", ledgerCodes: codes), Owner(name: "Private")],
                        categories: [invoices, receipts, letters])
    }

    // MARK: Settings

    @Test func oneListPerOwnerForCategoriesThatUseIt() {
        let settings = Self.settings
        #expect(settings.ledgerCodes(owner: "Company1", category: "Invoices") == Self.codes)
        #expect(settings.ledgerCodes(owner: "Company1", category: "Receipts") == Self.codes)
        #expect(settings.ledgerCodes(owner: "Company1", category: "Letters").isEmpty)
        #expect(settings.ledgerCodes(owner: "Private", category: "Invoices").isEmpty)
        #expect(settings.ledgerCodes(owner: "Unknown", category: "Invoices").isEmpty)
    }

    @Test func cleaningDropsEmptyRowsAndTrims() {
        var settings = Self.settings
        settings.owners[1].ledgerCodes = [LedgerCode(code: " 8000 ", description: " Omzet "), LedgerCode(code: "", description: " ")]
        let cleaned = settings.cleaningLedgerCodes()
        #expect(cleaned.owners[1].ledgerCodes.map(\.code) == ["8000"])
        #expect(cleaned.owners[1].ledgerCodes.map(\.description) == ["Omzet"])
        #expect(cleaned.owners[0].ledgerCodes == Self.codes)
    }

    @Test func validation() {
        #expect(Self.settings.validationErrors.isEmpty)
        var duplicate = Self.settings
        duplicate.owners[0].ledgerCodes.append(LedgerCode(code: "4300 ", description: "Again"))
        #expect(duplicate.validationErrors.count == 1)
        var missingCode = Self.settings
        missingCode.owners[0].ledgerCodes = [LedgerCode(code: "", description: "Huur")]
        #expect(missingCode.validationErrors.count == 1)
    }

    @Test func settingsFromBeforeLedgerCodesStillDecode() throws {
        let json = #"{"owners":[{"id":"\#(UUID().uuidString)","name":"Company1"}],"categories":[{"id":"\#(UUID().uuidString)","name":"Invoices"}]}"#
        let settings = try JSONDecoder().decode(ArchiveSettings.self, from: Data(json.utf8))
        #expect(settings.owners[0].ledgerCodes.isEmpty)
        #expect(!settings.categories[0].usesLedgerCodes)
        let current = Self.settings
        let again = try JSONDecoder().decode(ArchiveSettings.self, from: try JSONEncoder().encode(current))
        #expect(again == current)
    }

    @Test func personalOwner() throws {
        let json = #"{"owners":[{"id":"\#(UUID().uuidString)","name":"Londar"},{"id":"\#(UUID().uuidString)","name":"Werkgever"},{"id":"\#(UUID().uuidString)","name":"Privé"}],"categories":[]}"#
        let settings = try JSONDecoder().decode(ArchiveSettings.self, from: Data(json.utf8))
        #expect(settings.owners.map(\.isPersonal) == [false, false, true])
        var changed = settings
        changed.owners[2].isPersonal = false
        changed.owners[1].isPersonal = true
        let again = try JSONDecoder().decode(ArchiveSettings.self, from: try JSONEncoder().encode(changed))
        #expect(again.owners.map(\.isPersonal) == [false, true, false])
        #expect(ArchiveSettings.defaults.owners.map(\.isPersonal) == [false, false, true])
    }

    @Test func listsPerCategoryMoveToTheOwner() throws {
        let invoices = UUID(), receipts = UUID(), letters = UUID()
        let json = #"""
        {"owners":[{"id":"\#(UUID().uuidString)","name":"Company1","ledgerLists":[
            {"categoryID":"\#(invoices.uuidString)","codes":[{"id":"\#(UUID().uuidString)","code":"4300","description":"Telefoon"}]},
            {"categoryID":"\#(receipts.uuidString)","codes":[{"id":"\#(UUID().uuidString)","code":"4600","description":"Reiskosten"},
                                                          {"id":"\#(UUID().uuidString)","code":"4300","description":"Telefoon (bon)"}]}]}],
         "categories":[{"id":"\#(invoices.uuidString)","name":"Invoices"},{"id":"\#(receipts.uuidString)","name":"Receipts"},
                       {"id":"\#(letters.uuidString)","name":"Letters"}]}
        """#
        let settings = try JSONDecoder().decode(ArchiveSettings.self, from: Data(json.utf8))
        #expect(settings.owners[0].ledgerCodes.map(\.code) == ["4300", "4600"])
        #expect(settings.owners[0].ledgerCodes[0].description == "Telefoon")
        #expect(settings.categories.map(\.usesLedgerCodes) == [true, true, false])
        // Saved again in the new form, without the old lists.
        let saved = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(!saved.contains("ledgerLists"))
    }

    // MARK: Learning

    @Test func ruleRemembersOneCodePerOwnerForAllCategories() throws {
        let invoice = ConfirmedFiling(sender: "Hotel Voorbeeld", owner: "Company1", category: "Invoices", ledgerCode: "4600")
        var rule = try #require(SenderRules.learn(from: invoice, existing: []))
        #expect(rule.ledgerCode(owner: "Company1") == "4600")

        let otherCompany = ConfirmedFiling(sender: "Hotel Voorbeeld", owner: "Company2", category: "Receipts", ledgerCode: "7100")
        rule = try #require(SenderRules.learn(from: otherCompany, existing: [rule]))
        #expect(rule.ledgerCode(owner: "Company1") == "4600")
        #expect(rule.ledgerCode(owner: "Company2") == "7100")

        let receipt = ConfirmedFiling(sender: "Hotel Voorbeeld", owner: "Company1", category: "Receipts", ledgerCode: "4610")
        rule = try #require(SenderRules.learn(from: receipt, existing: [rule]))
        #expect(rule.ledgerCode(owner: "Company1") == "4610")
    }

    @Test func paidPrivatelyLearnsTheReimbursingCompanysCode() throws {
        let filing = ConfirmedFiling(sender: "Hotel Voorbeeld", owner: "Private", category: "Receipts", reimbursedBy: "Company1", ledgerCode: "4600")
        let rule = try #require(SenderRules.learn(from: filing, existing: []))
        #expect(rule.ledgerCode(owner: "Company1") == "4600")
        #expect(rule.ledgerCode(owner: "Private") == nil)
        #expect(ArchiveSettings.bookingOwner(owner: "Private", reimbursedBy: "Company1") == "Company1")
        #expect(ArchiveSettings.bookingOwner(owner: "Company1", reimbursedBy: nil) == "Company1")
    }

    @Test func vatLedgerCodePerRate() throws {
        var owner = Owner(name: "Company1", vatPeriod: .quarter)
        owner.setVATLedgerCode("1511", rate: 9)
        owner.setVATLedgerCode("1510", rate: 21)
        #expect(owner.vatLedgerCodes.map(\.rate) == [21, 9])
        #expect(owner.vatLedgerCode(rate: 21) == "1510")
        owner.setVATLedgerCode("", rate: 9)
        #expect(owner.vatLedgerCode(rate: 9) == nil)
        var settings = ArchiveSettings(owners: [owner], categories: [Self.invoices])
        settings.owners[0].vatLedgerCodes.append(VATLedgerCode(rate: 9, code: "  "))
        #expect(settings.cleaningLedgerCodes().owners[0].vatLedgerCodes == [VATLedgerCode(rate: 21, code: "1510")])
        let again = try JSONDecoder().decode(ArchiveSettings.self, from: try JSONEncoder().encode(settings))
        #expect(again.owners[0].vatLedgerCode(rate: 21) == "1510")
    }

    @Test func noListLeavesTheCodeAloneAndAnEmptyChoiceForgetsIt() throws {
        let first = try #require(SenderRules.learn(from: ConfirmedFiling(sender: "Praatnet", owner: "Company1", category: "Invoices", ledgerCode: "4300"), existing: []))
        let noList = try #require(SenderRules.learn(from: ConfirmedFiling(sender: "Praatnet", owner: "Company1", category: "Letters"), existing: [first]))
        #expect(noList.ledgerCode(owner: "Company1") == "4300")
        let cleared = try #require(SenderRules.learn(from: ConfirmedFiling(sender: "Praatnet", owner: "Company1", category: "Invoices", ledgerCode: ""), existing: [noList]))
        #expect(cleared.ledgerCode(owner: "Company1") == nil)
    }

    @Test func storedRuleKeepsItsCodes() {
        let rule = SenderRule(senderName: "Praatnet", aliases: ["praatnet"], owner: "Company1", category: "Invoices",
                              ledgerCodes: [LedgerChoice(owner: "Company1", code: "4300"), LedgerChoice(owner: "Company 2", code: "4510 A")])
        #expect(FilingRuleRecord(rule).rule.ledgerCodes == rule.ledgerCodes)
    }

    @Test func storedRuleFromPerCategoryVersionKeepsTheLastCodePerOwner() {
        let record = FilingRuleRecord(SenderRule(senderName: "Praatnet", aliases: ["praatnet"], owner: "Company1", category: "Invoices"))
        record.ledgerCodesText = "Company1\tInvoices\t4300\nCompany1\tReceipts\t4510\nCompany2\tInvoices\t7100"
        #expect(record.rule.ledgerCodes == [LedgerChoice(owner: "Company1", code: "4510"), LedgerChoice(owner: "Company2", code: "7100")])
    }

    // MARK: Model answer

    @Test func answerMustBeInTheList() {
        #expect(LedgerSuggestion.match("4510", in: Self.codes)?.code == "4510")
        #expect(LedgerSuggestion.match(" \"4600\" ", in: Self.codes)?.code == "4600")
        #expect(LedgerSuggestion.match("4300 – Telefoon en internet", in: Self.codes)?.code == "4300")
        #expect(LedgerSuggestion.match("reiskosten", in: Self.codes)?.code == "4600")
        #expect(LedgerSuggestion.match("43001", in: Self.codes) == nil)
        #expect(LedgerSuggestion.match("9999", in: Self.codes) == nil)
        #expect(LedgerSuggestion.match("", in: Self.codes) == nil)
    }

    @Test func longestCodeWinsAsPrefix() {
        let codes = [LedgerCode(code: "43"), LedgerCode(code: "4300")]
        #expect(LedgerSuggestion.match("4300 Telefoon", in: codes)?.code == "4300")
    }

    @Test func listIsTrimmedToFit() {
        let many = (1...500).map { LedgerCode(code: String(4000 + $0), description: "Kostenpost nummer \($0)") }
        let text = LedgerSuggestion.describe(many)
        #expect(text.count <= LedgerSuggestion.maxListLength)
        #expect(text.hasPrefix("- 4001: Kostenpost nummer 1\n"))
        #expect(LedgerSuggestion.describe([LedgerCode(code: "4300")]) == "- 4300")
        let prompt = LedgerSuggestion.prompt(sender: "Praatnet", description: "", text: String(repeating: "x", count: 10_000))
        #expect(prompt.hasPrefix("Sender: Praatnet\nDocument text:"))
        #expect(prompt.count < LedgerSuggestion.maxTextLength + 100)
    }
}
