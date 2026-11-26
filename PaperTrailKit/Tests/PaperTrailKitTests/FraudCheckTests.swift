import Foundation
import Testing
@testable import PaperTrailKit

/// Invoice fraud: a familiar sender with a new IBAN or a new payment page. Synthetic data only.
@Suite("Fraud checks")
struct FraudCheckTests {
    static let known = SenderRule(senderName: "Praatnet", aliases: ["praatnet"], ibans: ["NL00TEST0111222333"],
                                  owner: "Company1", category: "Invoices", paymentHosts: ["pay.example-psp.test"])

    @Test func ibanCheck() {
        #expect(SenderRules.checkIBAN("NL00 TEST 0111 2223 33", rule: Self.known) == .known)
        #expect(SenderRules.checkIBAN("NL00TEST0999888777", rule: Self.known) == .changed(known: ["NL00TEST0111222333"]))
        #expect(SenderRules.checkIBAN("NL00TEST0999888777", rule: nil) == .nothingKnown)
        #expect(SenderRules.checkIBAN("", rule: Self.known) == .nothingKnown)
        var noIBAN = Self.known
        noIBAN.ibans = []
        #expect(SenderRules.checkIBAN("NL00TEST0999888777", rule: noIBAN) == .nothingKnown)
    }

    @Test func changedIBANIsLearnedOnlyWhenConfirmed() throws {
        let fake = ConfirmedFiling(sender: "Praatnet", owner: "Company1", category: "Invoices", payToIban: "NL00TEST0999888777")
        let unconfirmed = try #require(SenderRules.learn(from: fake, existing: [Self.known]))
        #expect(unconfirmed.ibans == ["NL00TEST0111222333"])

        var checked = fake
        checked.ibanConfirmed = true
        let confirmed = try #require(SenderRules.learn(from: checked, existing: [Self.known]))
        #expect(confirmed.ibans == ["NL00TEST0111222333", "NL00TEST0999888777"])

        // A new sender's first IBAN is learned without asking.
        let first = try #require(SenderRules.learn(from: ConfirmedFiling(sender: "Nieuwe Leverancier", owner: "Company1", category: "Invoices",
                                                                         payToIban: "NL00TEST0444555666"), existing: []))
        #expect(first.ibans == ["NL00TEST0444555666"])
        #expect(SenderRules.confirming(iban: "NL00 TEST 0999 8887 77", in: Self.known).ibans.last == "NL00TEST0999888777")
    }

    @Test func ruleBySenderName() {
        let older = SenderRule(senderName: "Praatnet", aliases: ["praatnet"], owner: "Private", category: "Invoices", updatedAt: .distantPast)
        #expect(SenderRules.rule(forSender: "PRAATNET", in: [older, Self.known])?.id == Self.known.id)
        #expect(SenderRules.rule(forSender: "Onbekend Bedrijf", in: [Self.known]) == nil)
    }

    @Test func paymentHostCheck() {
        #expect(SenderRules.checkPaymentHost("pay.example-psp.test", rule: Self.known) == .known)
        #expect(SenderRules.checkPaymentHost("praatnet-betalen.example", rule: Self.known) == .new(known: ["pay.example-psp.test"]))
        #expect(SenderRules.checkPaymentHost("pay.example-psp.test", rule: nil) == .nothingKnown)
        let accepted = SenderRules.accepting(paymentHost: "www.Betaal.Example.test", in: Self.known)
        #expect(accepted.paymentHosts == ["pay.example-psp.test", "betaal.example.test"])
        #expect(SenderRules.checkPaymentHost("betaal.example.test", rule: accepted) == .known)
    }

    @Test func storedAndExportedRuleKeepHosts() throws {
        #expect(FilingRuleRecord(Self.known).rule.paymentHosts == ["pay.example-psp.test"])
        #expect(IndexExport.Rule(Self.known).rule.paymentHosts == ["pay.example-psp.test"])
    }

    @Test func bankNamesAloneDontMakeAPaymentLink() {
        #expect(!PaymentCode.isPaymentLink("https://rabo-verify.example.test/login"))
        #expect(PaymentCode.isPaymentLink("https://betaalverzoek.example.test/abc"))
    }
}
