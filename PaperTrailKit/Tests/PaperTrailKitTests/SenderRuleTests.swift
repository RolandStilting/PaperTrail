import Foundation
import Testing
@testable import PaperTrailKit

@Suite("SenderRules")
struct SenderRuleTests {
    static let day = Date(timeIntervalSince1970: 1_772_000_000)

    @Test func learnsANewRule() throws {
        let filing = ConfirmedFiling(sender: "Praatnet", suggestedSender: "Praatnet Demo", owner: "Company1",
                                     category: "Invoices", payToIban: "NL00 TEST 0111 2223 33")
        let rule = try #require(SenderRules.learn(from: filing, existing: [], now: Self.day))
        #expect(rule.senderName == "Praatnet")
        #expect(rule.aliases == ["praatnet", "praatnet demo"])
        #expect(rule.ibans == ["NL00TEST0111222333"])
        #expect(rule.owner == "Company1")
    }

    @Test func correctionUpdatesTheExistingRule() throws {
        let old = SenderRule(senderName: "Testmarkt", aliases: ["testmarkt"], owner: "Private", category: "Invoices", updatedAt: Self.day)
        let filing = ConfirmedFiling(sender: "Testmarkt", owner: "Private", category: "Receipts")
        let rule = try #require(SenderRules.learn(from: filing, existing: [old], now: Self.day.addingTimeInterval(60)))
        #expect(rule.id == old.id)
        #expect(rule.category == "Receipts")
    }

    @Test func doesNotLearnWithoutSender() {
        #expect(SenderRules.learn(from: ConfirmedFiling(sender: " ", owner: "Private", category: "Other"), existing: []) == nil)
        #expect(SenderRules.learn(from: ConfirmedFiling(sender: "AB", owner: "Private", category: "Other"), existing: []) == nil)
    }

    @Test func matchesSenderNameAsWholeWords() {
        let rule = SenderRule(senderName: "Praatnet", aliases: ["praatnet demo", "praatnet"], owner: "Company1", category: "Invoices")
        #expect(SenderRules.match([rule], text: "PRAATNET DEMO B.V.\nHerinnering") == rule)
        #expect(SenderRules.match([rule], text: "Praatnetwerk Nederland") == nil)
    }

    @Test func ibanBeatsName() {
        let byName = SenderRule(senderName: "Voorbeeld", aliases: ["voorbeeld energie"], owner: "Private", category: "Invoices")
        let byIban = SenderRule(senderName: "Energie Twee", aliases: ["energie twee"], ibans: ["NL00TEST0123456789"], owner: "Company2", category: "Invoices")
        let text = "Voorbeeld Energie\nOvermaken op NL00 TEST 0123 4567 89"
        #expect(SenderRules.match([byName, byIban], text: text) == byIban)
    }

    @Test func longestNameWins() {
        let short = SenderRule(senderName: "Gemeente", aliases: ["gemeente"], owner: "Private", category: "Letters")
        let long = SenderRule(senderName: "Gemeente Fictiedam", aliases: ["gemeente fictiedam"], owner: "Private", category: "Tax")
        #expect(SenderRules.match([short, long], text: "Gemeente Fictiedam, Afdeling Belastingen") == long)
    }

    @Test func recordRoundTrips() {
        let rule = SenderRule(senderName: "KPN", aliases: ["kpn"], ibans: ["NL00TEST0123456789"], owner: "Company1", category: "Invoices", updatedAt: Self.day)
        #expect(FilingRuleRecord(rule).rule == rule)
    }

    @Test func remembersAndForgetsReimbursement() throws {
        let first = try #require(SenderRules.learn(from: ConfirmedFiling(sender: "Parkeren Test", owner: "Private", category: "Receipts", reimbursedBy: "Company1"), existing: [], now: Self.day))
        #expect(first.reimbursedBy == "Company1")
        #expect(FilingRuleRecord(first).rule.reimbursedBy == "Company1")
        let second = try #require(SenderRules.learn(from: ConfirmedFiling(sender: "Parkeren Test", owner: "Private", category: "Receipts"), existing: [first], now: Self.day.addingTimeInterval(60)))
        #expect(second.reimbursedBy == nil)
    }

    @Test func sharedIBANDoesNotDecide() {
        // Two senders paid through the same payment provider IBAN.
        let energy = SenderRule(senderName: "Voorbeeld Energie", aliases: ["voorbeeld energie"], ibans: ["NL91ABNA0417164300"], owner: "Private", category: "Invoices", updatedAt: Self.day.addingTimeInterval(60))
        let painter = SenderRule(senderName: "Schildersbedrijf Voorbeeld", aliases: ["schildersbedrijf voorbeeld"], ibans: ["NL91ABNA0417164300"], owner: "Company1", category: "Invoices", updatedAt: Self.day)
        let text = "Schildersbedrijf Voorbeeld\nFactuur\nNL91 ABNA 0417 1643 00"
        #expect(SenderRules.match([energy, painter], text: text) == painter)
        #expect(SenderRules.match([energy, painter], text: "Factuur\nNL91 ABNA 0417 1643 00") == nil)
    }

    @Test func sameIBANForAnotherSenderMakesANewRule() throws {
        let painter = try #require(SenderRules.learn(from: ConfirmedFiling(sender: "Schildersbedrijf Voorbeeld", owner: "Company1", category: "Invoices",
                                                                          payToIban: "NL91ABNA0417164300"), existing: [], now: Self.day))
        let energy = try #require(SenderRules.learn(from: ConfirmedFiling(sender: "Voorbeeld Energie", owner: "Private", category: "Invoices",
                                                                         payToIban: "NL91ABNA0417164300"), existing: [painter], now: Self.day.addingTimeInterval(60)))
        #expect(energy.id != painter.id)
        #expect(energy.senderName == "Voorbeeld Energie")
        #expect(SenderRules.match([painter, energy], text: "Schildersbedrijf Voorbeeld\nNL91 ABNA 0417 1643 00") == painter)
    }
}
