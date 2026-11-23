import PaperTrailKit
import SwiftData
import SwiftUI

/// The review screen: the app suggests category, sender, description, dates and payment
/// details on the device; the user checks them and files the document.
struct FilingView: View {
    enum Field: Hashable { case owner, category, documentDate, sender, description, bill, reimbursement }

    enum SuggestionState: Equatable {
        case waitingForText
        case working
        case done
        case unavailable(String)
        case failed
    }

    let document: PendingDocument
    let filingService: FilingService
    let billService: BillService
    var onDone: () -> Void

    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.modelContext) private var modelContext
    @Query private var ruleRecords: [FilingRuleRecord]

    @State private var ownerName = ""
    @State private var categoryName = ""
    @State private var receivedDate = Date.now
    @State private var hasDocumentDate = false
    @State private var documentDate = Date.now
    @State private var sender = ""
    @State private var descriptionText = ""

    @State private var isUnpaidBill = false
    @State private var amount: Double?
    @State private var hasDueDate = false
    @State private var dueDate = Date.now
    @State private var iban = ""
    @State private var paymentReference = ""
    /// Empty: not a reimbursable expense.
    @State private var reimbursedBy = ""

    @State private var suggestion = SuggestionState.waitingForText
    /// Fields the user changed; a late suggestion never overwrites them.
    @State private var edited: Set<Field> = []
    /// The learned rule that matched this document; its owner, category and sender win over the model.
    @State private var appliedRule: SenderRule?
    /// The sender the model suggested, remembered as an alias when a rule is learned.
    @State private var suggestedSender = ""
    /// Set when the document looks like one already filed; the user decides whether to file anyway.
    @State private var duplicate: DuplicateMatch?
    /// Set when the document was filed but its reminder could not be created.
    @State private var reminderProblem: String?

    @State private var extractedText: String?
    @State private var ocrFailed = false
    @State private var isFiling = false
    @State private var errorMessage: String?

    private var request: FilingRequest {
        FilingRequest(
            owner: ownerName, category: categoryName, receivedDate: receivedDate,
            documentDate: hasDocumentDate ? documentDate : nil, sender: sender, description: descriptionText,
            bill: bill, reimbursedBy: reimbursedBy.isEmpty || reimbursedBy == ownerName ? nil : reimbursedBy
        )
    }

    private var bill: BillDetails? {
        let details = BillDetails(
            isUnpaid: isUnpaidBill, amount: amount, dueDate: hasDueDate ? dueDate : nil,
            iban: iban.uppercased().filter { $0.isLetter || $0.isNumber },
            reference: paymentReference.trimmingCharacters(in: .whitespaces)
        )
        return details.isEmpty ? nil : details
    }

    /// Wraps a binding so that changing it marks the field as edited by the user.
    private func tracked<Value>(_ binding: Binding<Value>, _ field: Field) -> Binding<Value> {
        Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0; edited.insert(field) })
    }

    private var previewPath: String? {
        try? FilingPlanner.plan(for: request, namer: filingService.namer).relativePath
    }

    var body: some View {
        Form {
            Section {
                PDFPreview(data: document.pdfData)
                    .frame(minHeight: 260)
            }

            suggestionSection

            Section("Where") {
                Picker("Owner", selection: tracked($ownerName, .owner)) {
                    ForEach(settingsStore.settings.owners) { Text($0.name).tag($0.name) }
                }
                Picker("Category", selection: tracked($categoryName, .category)) {
                    ForEach(settingsStore.settings.categories) { Text($0.name).tag($0.name) }
                }
            }

            Section("Details") {
                DatePicker("Received", selection: $receivedDate, displayedComponents: .date)
                Toggle("Date on document", isOn: tracked($hasDocumentDate, .documentDate))
                if hasDocumentDate {
                    DatePicker("Document date", selection: tracked($documentDate, .documentDate), displayedComponents: .date)
                }
                TextField("Sender", text: tracked($sender, .sender), prompt: Text("e.g. Acme Energy"))
                TextField("Description", text: tracked($descriptionText, .description), prompt: Text("At most 6 words"))
            }

            Section {
                Toggle("Unpaid bill", isOn: tracked($isUnpaidBill, .bill))
                TextField("Amount", value: tracked($amount, .bill), format: .currency(code: "EUR"), prompt: Text("€ 0.00"))
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                if isUnpaidBill {
                    Toggle("Due date", isOn: tracked($hasDueDate, .bill))
                    if hasDueDate {
                        DatePicker("Pay before", selection: tracked($dueDate, .bill), displayedComponents: .date)
                    }
                    TextField("IBAN", text: tracked($iban, .bill), prompt: Text("NL00 BANK 0123 4567 89"))
                        .autocorrectionDisabled()
                    TextField("Payment reference", text: tracked($paymentReference, .bill))
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Payment")
            } footer: {
                if isUnpaidBill {
                    Text("Unpaid bills will get a reminder in a later version.")
                }
            }

            Section {
                Picker("To be reimbursed by", selection: tracked($reimbursedBy, .reimbursement)) {
                    Text("Nobody").tag("")
                    ForEach(settingsStore.settings.owners.filter { $0.name != ownerName }) { Text($0.name).tag($0.name) }
                }
            } header: {
                Text("Expense")
            } footer: {
                Text("For a personal expense a company pays back. It appears under Expenses until it's claimed and reimbursed.")
            }

            Section("File name") {
                if let previewPath {
                    Text(previewPath)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                } else {
                    Text("Choose an owner and a category.")
                        .foregroundStyle(.secondary)
                }
            }

            if document.reviewItemURL == nil {
                Section {
                    Button("Review Later", systemImage: "tray.and.arrow.down") { Task { await saveForReview() } }
                        .disabled(isFiling)
                } footer: {
                    Text("Saves the document to Needs Review in iCloud Drive, so you can file it later on any device.")
                }
            }

            Section("Recognised text") {
                if let extractedText {
                    DisclosureGroup(extractedText.isEmpty ? "No text found" : "Show text") {
                        Text(extractedText)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                    .disabled(extractedText.isEmpty)
                } else if ocrFailed {
                    Text("Text recognition failed. You can still file the document.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        ProgressView()
                        Text("Recognising text…")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("File document")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onDone)
                    .disabled(isFiling)
            }
            ToolbarItem(placement: .confirmationAction) {
                if isFiling {
                    ProgressView()
                } else {
                    Button("File") { Task { await checkAndFile() } }
                        .disabled(previewPath == nil)
                }
            }
        }
        .alert("Could not file the document", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Already filed?", isPresented: Binding(get: { duplicate != nil }, set: { if !$0 { duplicate = nil } }), presenting: duplicate) { _ in
            Button("File Anyway") { Task { await file() } }
            Button("Cancel", role: .cancel) {}
        } message: { match in
            Text("\(match.reason.message) An earlier document is in your archive:\n\(match.existing.relativePath)")
        }
        .alert("Filed, but no reminder", isPresented: Binding(get: { reminderProblem != nil }, set: { if !$0 { reminderProblem = nil; onDone() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(reminderProblem ?? "")
        }
        .interactiveDismissDisabled(isFiling)
        .onAppear(perform: applyDefaults)
        .task { await recognizeText() }
    }

    @ViewBuilder
    private var suggestionSection: some View {
        if let appliedRule {
            Section {
                Label("Filed like earlier documents from \(appliedRule.senderName). Change owner or category to update this rule.", systemImage: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
            }
        }
        switch suggestion {
        case .waitingForText, .working:
            Section {
                HStack {
                    ProgressView()
                    Text("Suggesting details on this device…")
                }
            }
        case .done:
            Section {
                Label("Details suggested on this device. Check them before filing.", systemImage: "sparkles")
                    .foregroundStyle(.secondary)
            }
        case .unavailable(let reason):
            Section {
                Label(reason, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        case .failed:
            Section {
                Label("Could not suggest details for this document. Fill them in yourself.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func saveForReview() async {
        isFiling = true
        defer { isFiling = false }
        do {
            try await filingService.saveForReview(document)
            onDone()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyDefaults() {
        if let received = document.receivedDate { receivedDate = received }
        if ownerName.isEmpty { ownerName = settingsStore.settings.owners.first?.name ?? "" }
        if categoryName.isEmpty { categoryName = settingsStore.settings.categories.first?.name ?? "" }
    }

    private func recognizeText() async {
        let recognizer = VisionTextRecognizer()
        do {
            if document.pageImages.isEmpty {
                extractedText = try await PDFTextExtractor(recognizer: recognizer).extractText(from: document.pdfData)
            } else {
                extractedText = try await recognizer.recognizeText(in: document.pageImages)
            }
        } catch is CancellationError {
            return
        } catch {
            ocrFailed = true
            suggestion = .failed
            return
        }
        applyRule()
        await suggestDetails()
    }

    /// Learned rules run before the model, and also work when the model is unavailable.
    private func applyRule() {
        guard let text = extractedText,
              let rule = SenderRules.match(ruleRecords.map(\.rule), text: text) else { return }
        appliedRule = rule
        let settings = settingsStore.settings
        // Skip values whose owner or category was removed from Settings since.
        if !edited.contains(.owner), settings.owners.contains(where: { $0.name == rule.owner }) {
            ownerName = rule.owner
        }
        if !edited.contains(.category), settings.categories.contains(where: { $0.name == rule.category }) {
            categoryName = rule.category
        }
        if !edited.contains(.sender) { sender = rule.senderName }
        if !edited.contains(.reimbursement), let company = rule.reimbursedBy,
           settings.owners.contains(where: { $0.name == company }), company != ownerName {
            reimbursedBy = company
        }
    }

    /// Asks the on-device model for a proposal. Document text never leaves the device.
    private func suggestDetails() async {
        guard let text = extractedText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            suggestion = .failed
            return
        }
        if case .unavailable(let reason) = ModelExtractor.availability {
            suggestion = .unavailable(reason.message)
            return
        }
        suggestion = .working
        let categories = settingsStore.settings.categories.map(\.name)
        do {
            let proposal = try await ModelExtractor(categories: categories).proposal(for: text)
            apply(proposal)
            suggestion = .done
        } catch is CancellationError {
            return
        } catch {
            suggestion = .failed
        }
    }

    /// Fills in suggested values, leaving fields the user already changed alone.
    private func apply(_ proposal: Proposal) {
        suggestedSender = proposal.sender
        let ruleWins = appliedRule != nil
        if !edited.contains(.category), !ruleWins, !proposal.category.isEmpty { categoryName = proposal.category }
        if !edited.contains(.sender), !ruleWins, !proposal.sender.isEmpty { sender = proposal.sender }
        if !edited.contains(.description), !proposal.description.isEmpty { descriptionText = proposal.description }
        if !edited.contains(.documentDate), let date = proposal.documentDate {
            documentDate = date
            hasDocumentDate = true
        }
        if !edited.contains(.bill) {
            isUnpaidBill = proposal.bill.isUnpaid
            amount = proposal.bill.amount
            if let due = proposal.bill.dueDate {
                dueDate = due
                hasDueDate = true
            }
            iban = proposal.bill.iban
            paymentReference = proposal.bill.reference
        }
    }

    /// Warns about a probable duplicate before filing. If the check itself fails, filing
    /// goes ahead: a missed warning is better than a document that can't be filed.
    private func checkAndFile() async {
        if let match = try? filingService.duplicates(of: document, request: request, context: modelContext).first {
            duplicate = match
            return
        }
        await file()
    }

    private func file() async {
        isFiling = true
        defer { isFiling = false }
        do {
            let record = try await filingService.file(document, request: request, extractedText: extractedText, suggestedSender: suggestedSender, context: modelContext)
            do {
                try await billService.addReminder(for: record, context: modelContext)
            } catch {
                // The document is safely filed; only the reminder is missing.
                reminderProblem = error.localizedDescription
                return
            }
            onDone()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
