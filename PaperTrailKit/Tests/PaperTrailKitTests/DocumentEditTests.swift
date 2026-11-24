import Foundation
import Testing
@testable import PaperTrailKit

@Suite("DocumentEdit")
struct DocumentEditTests {
    let plan = FilingPlan(folderComponents: ["Private", "2026", "Invoices"], fileName: "2026-11-23 Voorbeeld Energie - Jaarnota.pdf")

    @Test func unchangedFileStaysPut() {
        #expect(DocumentEdit.isAlreadyAt("Private/2026/Invoices/2026-11-23 Voorbeeld Energie - Jaarnota.pdf", plan: plan))
        #expect(DocumentEdit.isAlreadyAt("Private/2026/Invoices/2026-11-23 Voorbeeld Energie - Jaarnota (2).pdf", plan: plan))
        #expect(DocumentEdit.isAlreadyAt("private/2026/invoices/2026-11-23 voorbeeld energie - jaarnota.pdf", plan: plan))
    }

    @Test func changedNameOrFolderMoves() {
        #expect(!DocumentEdit.isAlreadyAt("Private/2026/Invoices/2026-11-23 Voorbeeld Energie - Nota.pdf", plan: plan))
        #expect(!DocumentEdit.isAlreadyAt("Company1/2026/Invoices/2026-11-23 Voorbeeld Energie - Jaarnota.pdf", plan: plan))
        #expect(!DocumentEdit.isAlreadyAt("Private/2026/Letters/2026-11-23 Voorbeeld Energie - Jaarnota.pdf", plan: plan))
        // A year in brackets is not a collision number.
        #expect(!DocumentEdit.isPlannedName("Nota (2026).pdf", planned: "Nota.pdf"))
        #expect(DocumentEdit.isPlannedName("Nota (3).pdf", planned: "Nota.pdf"))
        #expect(!DocumentEdit.isPlannedName("Nota (3).pdf", planned: "Notitie.pdf"))
    }

    func facts(owner: String = "Private", amount: Double? = 42.5, path: String = "a.pdf") -> DocumentEdit.ReminderFacts {
        .init(owner: owner, sender: "Voorbeeld Energie", amount: amount, dueDate: nil, iban: "NL00TEST0123456789", reference: "TEST-1", relativePath: path)
    }

    @Test func reminderChanges() {
        let a = facts()
        #expect(DocumentEdit.reminderChange(before: a, after: a, wasUnpaidBill: true, isUnpaidBill: true, isPaid: false, hasReminder: true) == .keep)
        #expect(DocumentEdit.reminderChange(before: a, after: facts(amount: 50), wasUnpaidBill: true, isUnpaidBill: true, isPaid: false, hasReminder: true) == .replace)
        #expect(DocumentEdit.reminderChange(before: a, after: facts(owner: "Company1"), wasUnpaidBill: true, isUnpaidBill: true, isPaid: false, hasReminder: true) == .replace)
        #expect(DocumentEdit.reminderChange(before: a, after: a, wasUnpaidBill: true, isUnpaidBill: false, isPaid: false, hasReminder: true) == .remove)
        #expect(DocumentEdit.reminderChange(before: a, after: a, wasUnpaidBill: false, isUnpaidBill: true, isPaid: false, hasReminder: false) == .create)
        // An unpaid bill whose reminder could not be made earlier gets one now.
        #expect(DocumentEdit.reminderChange(before: a, after: a, wasUnpaidBill: true, isUnpaidBill: true, isPaid: false, hasReminder: false) == .create)
        // Paid bills keep their completed reminder.
        #expect(DocumentEdit.reminderChange(before: a, after: facts(amount: 1), wasUnpaidBill: true, isUnpaidBill: false, isPaid: true, hasReminder: true) == .keep)
    }

    @Test func submittedVATReturnLocks() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let returns = [DocumentEdit.SubmittedReturn(owner: "Company1", start: start, end: end)]
        let august = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15))!
        let october = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        #expect(DocumentEdit.isInSubmittedVATReturn(owner: "Company1", reimbursedBy: nil, vatDate: august, returns: returns))
        #expect(DocumentEdit.isInSubmittedVATReturn(owner: "Private", reimbursedBy: "Company1", vatDate: august, returns: returns))
        #expect(!DocumentEdit.isInSubmittedVATReturn(owner: "Company1", reimbursedBy: nil, vatDate: october, returns: returns))
        #expect(!DocumentEdit.isInSubmittedVATReturn(owner: "Private", reimbursedBy: nil, vatDate: august, returns: returns))
    }
}

@Suite("SenderRules releasing")
struct SenderRulesReleasingTests {
    @Test func otherRulesDropTheOldName() {
        let old = SenderRule(senderName: "Voorbeeld Energi", owner: "Private", category: "Letters", updatedAt: .distantPast)
        var oldRule = old
        oldRule.aliases = ["voorbeeld energi"]
        var shared = SenderRule(senderName: "Voorbeeld", owner: "Private", category: "Letters", updatedAt: .distantPast)
        shared.aliases = ["voorbeeld", "voorbeeld energi"]
        var kept = SenderRule(senderName: "Voorbeeld Energie", owner: "Company1", category: "Invoices", updatedAt: .now)
        kept.aliases = ["voorbeeld energie", "voorbeeld energi"]

        let changed = SenderRules.releasing(oldName: "Voorbeeld Energi", keeping: kept.id, in: [oldRule, shared, kept])
        #expect(changed.count == 2)
        #expect(changed.first { $0.id == oldRule.id }?.aliases == [])
        #expect(changed.first { $0.id == shared.id }?.aliases == ["voorbeeld"])
    }
}
