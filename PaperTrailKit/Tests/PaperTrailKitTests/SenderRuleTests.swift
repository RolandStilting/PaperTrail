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
}
