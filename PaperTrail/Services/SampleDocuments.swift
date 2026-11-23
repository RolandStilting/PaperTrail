#if DEBUG
import Foundation
import PaperTrailKit
import SwiftData

/// Debug builds only: files a handful of made-up documents (invented companies and amounts,
/// the public example IBAN from IBAN documentation) to try the screens in the Simulator.
enum SampleDocuments {
    struct Sample {
        var owner: String, category: String, sender: String, description: String
        var monthsAgo: Int, amount: Double, unpaidDueInDays: Int? = nil
        var reimbursedBy: String? = nil, vatRate: Double? = nil
    }

    static let samples: [Sample] = [
        Sample(owner: "Company1", category: "Invoices", sender: "Schildersbedrijf Voorbeeld", description: "Schilderwerk kozijnen",
               monthsAgo: 0, amount: 853.66, unpaidDueInDays: 5, vatRate: 21),
        Sample(owner: "Company1", category: "Invoices", sender: "Example Cloud", description: "Abonnement november",
               monthsAgo: 0, amount: 29.00, vatRate: 21),
        Sample(owner: "Private", category: "Receipts", sender: "Parkeergarage Proef", description: "Parkeren centrum",
               monthsAgo: 0, amount: 12.10, reimbursedBy: "Company1", vatRate: 21),
        Sample(owner: "Private", category: "Invoices", sender: "Voorbeeld Energie", description: "Energierekening oktober",
               monthsAgo: 1, amount: 142.37, unpaidDueInDays: -2),
        Sample(owner: "Company2", category: "Invoices", sender: "Drukkerij Test", description: "Visitekaartjes",
               monthsAgo: 1, amount: 96.80, vatRate: 21),
        Sample(owner: "Private", category: "Receipts", sender: "Testmarkt", description: "Boodschappen",
               monthsAgo: 2, amount: 23.85),
        Sample(owner: "Private", category: "Letters", sender: "Gemeente Fictiedam", description: "Brief parkeervergunning",
               monthsAgo: 3, amount: 0),
    ]

    static func add(using filingService: FilingService, context: ModelContext) async throws {
        let calendar = Calendar.current
        for sample in samples {
            let received = calendar.date(byAdding: .month, value: -sample.monthsAgo, to: .now) ?? .now
            let line = ClaimLine(date: received, sender: sample.sender, description: sample.description,
                                 amount: sample.amount > 0 ? sample.amount : nil, relativePath: "")
            let pdf = try ExpenseClaim.pdf(title: sample.sender, subtitle: sample.description, lines: [line], receipts: [])
            let bill = BillDetails(
                isUnpaid: sample.unpaidDueInDays != nil,
                amount: sample.amount > 0 ? sample.amount : nil,
                dueDate: sample.unpaidDueInDays.flatMap { calendar.date(byAdding: .day, value: $0, to: .now) },
                iban: sample.unpaidDueInDays != nil ? "NL91ABNA0417164300" : "",
                reference: sample.unpaidDueInDays != nil ? "TEST-\(Int(sample.amount * 100))" : ""
            )
            let vat = sample.vatRate.map { rate -> VATInfo in
                let vatAmount = ((sample.amount * rate / (100 + rate)) * 100).rounded() / 100
                return VATInfo(lines: [VATLine(rate: rate, base: ((sample.amount - vatAmount) * 100).rounded() / 100, amount: vatAmount)])
            }
            let request = FilingRequest(owner: sample.owner, category: sample.category, receivedDate: received, documentDate: received,
                                        sender: sample.sender, description: sample.description, bill: bill,
                                        reimbursedBy: sample.reimbursedBy, vat: vat)
            _ = try await filingService.file(PendingDocument(pdfData: pdf, source: .fileImport, originalName: "sample.pdf"),
                                             request: request, extractedText: "\(sample.sender) \(sample.description)", context: context)
        }
    }
}
#endif
