import Foundation
import Testing
@testable import PaperTrailKit

/// Synthetic data only (invented companies and codes).
@Suite("LedgerCodes")
struct LedgerCodeTests {
    static let invoices = DocumentCategory(name: "Invoices")
    static let receipts = DocumentCategory(name: "Receipts")
    static let codes = [
        LedgerCode(code: "4300", description: "Telefoon en internet"),
        LedgerCode(code: "4510", description: "Kantoorbenodigdheden"),
        LedgerCode(code: "4600", description: "Reiskosten"),
    ]

    static var settings: ArchiveSettings {
        var company = Owner(name: "Company1")
        company.setLedgerCodes(codes, categoryID: invoices.id)
        return ArchiveSettings(owners: [company, Owner(name: "Private")], categories: [invoices, receipts])
    }

    // MARK: Settings

    @Test func listIsPerOwnerAndCategory() {
        let settings = Self.settings
        #expect(settings.ledgerCodes(owner: "Company1", category: "Invoices") == Self.codes)
        #expect(settings.ledgerCodes(owner: "Company1", category: "Receipts").isEmpty)
        #expect(settings.ledgerCodes(owner: "Private", category: "Invoices").isEmpty)
        #expect(settings.ledgerCodes(owner: "Unknown", category: "Invoices").isEmpty)
    }

    @Test func renamingTheCategoryKeepsTheList() {
        var settings = Self.settings
        settings.categories[0].name = "Purchase invoices"
        #expect(settings.ledgerCodes(owner: "Company1", category: "Purchase invoices") == Self.codes)
    }

    @Test func cleaningDropsEmptyRowsAndListsOfRemovedCategories() {
        var settings = Self.settings
        settings.owners[0].setLedgerCodes([LedgerCode(code: " 8000 ", description: " Omzet "), LedgerCode(code: "", description: "")], categoryID: Self.receipts.id)
        settings.owners[1].setLedgerCodes([LedgerCode(code: "", description: " ")], categoryID: Self.invoices.id)
        settings.categories.removeFirst()
        let cleaned = settings.cleaningLedgerCodes()
        #expect(cleaned.owners[0].ledgerLists.count == 1)
        #expect(cleaned.owners[0].ledgerCodes(categoryID: Self.receipts.id).map(\.code) == ["8000"])
        #expect(cleaned.owners[0].ledgerCodes(categoryID: Self.receipts.id).map(\.description) == ["Omzet"])
        #expect(cleaned.owners[1].ledgerLists.isEmpty)
    }

    @Test func validation() {
        #expect(Self.settings.validationErrors.isEmpty)
        var duplicate = Self.settings
        duplicate.owners[0].setLedgerCodes(Self.codes + [LedgerCode(code: "4300 ", description: "Again")], categoryID: Self.invoices.id)
        #expect(duplicate.validationErrors.count == 1)
        var missingCode = Self.settings
        missingCode.owners[0].setLedgerCodes([LedgerCode(code: "", description: "Huur")], categoryID: Self.invoices.id)
        #expect(missingCode.validationErrors.count == 1)
    }

    @Test func settingsFromBeforeLedgerCodesStillDecode() throws {
        let json = #"{"owners":[{"id":"\#(UUID().uuidString)","name":"Company1"}],"categories":[{"id":"\#(UUID().uuidString)","name":"Invoices"}]}"#
        let settings = try JSONDecoder().decode(ArchiveSettings.self, from: Data(json.utf8))
        #expect(settings.owners[0].ledgerLists.isEmpty)
        let current = Self.settings
        let again = try JSONDecoder().decode(ArchiveSettings.self, from: try JSONEncoder().encode(current))
        #expect(again == current)
    }

    // MARK: Learning

    @Test func ruleRemembersACodePerOwnerAndCategory() throws {
        let invoice = ConfirmedFiling(sender: "Praatnet", owner: "Company1", category: "Invoices", ledgerCode: "4300")
        var rule = try #require(SenderRules.learn(from: invoice, existing: []))
        #expect(rule.ledgerCode(owner: "Company1", category: "Invoices") == "4300")

        let receipt = ConfirmedFiling(sender: "Praatnet", owner: "Company1", category: "Receipts", ledgerCode: "4510")
        rule = try #require(SenderRules.learn(from: receipt, existing: [rule]))
        #expect(rule.ledgerCode(owner: "Company1", category: "Invoices") == "4300")
        #expect(rule.ledgerCode(owner: "Company1", category: "Receipts") == "4510")
    }

    @Test func noListLeavesTheCodeAloneAndAnEmptyChoiceForgetsIt() throws {
        let first = try #require(SenderRules.learn(from: ConfirmedFiling(sender: "Praatnet", owner: "Company1", category: "Invoices", ledgerCode: "4300"), existing: []))
        let noList = try #require(SenderRules.learn(from: ConfirmedFiling(sender: "Praatnet", owner: "Company1", category: "Invoices"), existing: [first]))
        #expect(noList.ledgerCode(owner: "Company1", category: "Invoices") == "4300")
        let cleared = try #require(SenderRules.learn(from: ConfirmedFiling(sender: "Praatnet", owner: "Company1", category: "Invoices", ledgerCode: ""), existing: [noList]))
        #expect(cleared.ledgerCode(owner: "Company1", category: "Invoices") == nil)
    }

    @Test func storedRuleKeepsItsCodes() {
        let rule = SenderRule(senderName: "Praatnet", aliases: ["praatnet"], owner: "Company1", category: "Invoices",
                              ledgerCodes: [LedgerChoice(owner: "Company1", category: "Invoices", code: "4300"),
                                            LedgerChoice(owner: "Company 2", category: "Receipts", code: "4510 A")])
        #expect(FilingRuleRecord(rule).rule.ledgerCodes == rule.ledgerCodes)
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
