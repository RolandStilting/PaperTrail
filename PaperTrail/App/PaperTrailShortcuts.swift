import AppIntents
import Foundation
import PaperTrailKit
import SwiftData
import UniformTypeIdentifiers

// Shortcuts and Siri actions. The ones that tell amounts need an unlocked device, so Siri
// never reads them out on a locked iPhone. Everything stays on the device.

/// "What do I have to pay?" Answers with the number, total and what's overdue.
struct BillsToPayIntent: AppIntent {
    static let title: LocalizedStringResource = "Bills to Pay"
    static let description = IntentDescription("Tells how many bills are open in Paper Trail, their total and which are overdue.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let context = AppServices.modelContainer.mainContext
        let bills = try context.fetch(FetchDescriptor<DocumentRecord>(predicate: #Predicate { $0.isUnpaidBill && !$0.isPaid }))
        // Bills paid by completing their reminder since the app last looked.
        try? await BillService(reminders: EventKitBillReminders()).syncPaidState(bills: bills, context: context)
        let open = bills.filter(\.isOpenBill).map { ShortcutAnswers.Bill(sender: $0.sender, amount: $0.amount, dueDate: $0.dueDate) }
        let answer = ShortcutAnswers.billsToPay(open, today: .now)
        return .result(value: ShortcutAnswers.total(open.map(\.amount)), dialog: IntentDialog(stringLiteral: answer))
    }
}

/// Opens the To Pay list in the app.
struct OpenBillsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Bills to Pay"
    static let description = IntentDescription("Opens the list of open bills in Paper Trail, with payment codes and details.")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        AppServices.model?.billToOpen = nil
        AppServices.model?.showingBillFromLink = true
        return .result()
    }
}

/// "Which expenses can I claim?" Totals per company.
struct ExpensesToClaimIntent: AppIntent {
    static let title: LocalizedStringResource = "Expenses to Claim"
    static let description = IntentDescription("Tells per company how many expenses are waiting to be claimed and their total.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let records = try AppServices.modelContainer.mainContext.fetch(FetchDescriptor<DocumentRecord>(predicate: #Predicate { $0.reimbursedBy != nil }))
        let open = records.filter { $0.claimState == .open }
        let companies = Dictionary(grouping: open) { $0.reimbursedBy ?? "" }
            .sorted { $0.key < $1.key }
            .map { (company: $0.key, amounts: $0.value.map(\.amount)) }
        let answer = ShortcutAnswers.expensesToClaim(companies)
        return .result(value: ShortcutAnswers.total(open.map(\.amount)), dialog: IntentDialog(stringLiteral: answer))
    }
}

/// Puts a PDF or image in Needs Review, e.g. from the Share sheet, Files or a Mac Quick Action.
struct AddDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Paper Trail"
    static let description = IntentDescription("Adds a PDF or image to Needs Review in Paper Trail, to file on any of your devices.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Document", supportedContentTypes: [.pdf, .image])
    var document: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$document) to Paper Trail")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = document.filename
        let pending = try DocumentCapture.fromData(document.data, name: name, isPDF: document.type?.conforms(to: .pdf) == true, source: .shortcut)
        let filing = AppServices.model?.filingService ?? FilingService(location: ICloudArchiveLocation(), store: CoordinatedFileStore())
        try await filing.saveForReview(pending)
        await AppServices.model?.refreshReviewItems()
        return .result(dialog: IntentDialog(stringLiteral: String(localized: "\(name) is in Needs Review.")))
    }
}

/// Opens the first document waiting in Needs Review, ready to file.
struct ReviewDocumentsIntent: AppIntent {
    static let title: LocalizedStringResource = "Review Documents"
    static let description = IntentDescription("Opens the next document waiting in Needs Review so you can file it.")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppServices.model else { return .result(dialog: "Open Paper Trail first, then try again.") }
        await model.refreshReviewItems()
        guard let first = model.reviewItems.first else { return .result(dialog: "Nothing is waiting in Needs Review.") }
        await model.openReviewItem(first)
        return .result(dialog: IntentDialog(stringLiteral: String(localized: "\(model.reviewItems.count) documents waiting.")))
    }
}

/// Ready-made shortcuts and Siri phrases, available without setting anything up.
struct PaperTrailShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: BillsToPayIntent(),
                    phrases: ["What do I have to pay in \(.applicationName)", "Bills to pay in \(.applicationName)", "\(.applicationName) bills"],
                    shortTitle: "Bills to Pay", systemImageName: "eurosign.circle")
        AppShortcut(intent: OpenBillsIntent(),
                    phrases: ["Open bills in \(.applicationName)", "Show my bills in \(.applicationName)"],
                    shortTitle: "Open Bills", systemImageName: "qrcode")
        AppShortcut(intent: ExpensesToClaimIntent(),
                    phrases: ["Expenses to claim in \(.applicationName)", "\(.applicationName) expenses"],
                    shortTitle: "Expenses to Claim", systemImageName: "arrow.uturn.backward.circle")
        AppShortcut(intent: AddDocumentIntent(),
                    phrases: ["Add a document to \(.applicationName)", "File in \(.applicationName)"],
                    shortTitle: "Add to Paper Trail", systemImageName: "tray.and.arrow.down")
        AppShortcut(intent: ReviewDocumentsIntent(),
                    phrases: ["Review documents in \(.applicationName)", "File documents in \(.applicationName)"],
                    shortTitle: "Review Documents", systemImageName: "doc.text.magnifyingglass")
    }

    static let shortcutTileColor: ShortcutTileColor = .navy
}
