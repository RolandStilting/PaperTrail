import PaperTrailKit
import SwiftData
import SwiftUI

/// The review screen: the app suggests category, sender, description, dates and payment
/// details on the device; the user checks them and files the document. With `editing` set, the
/// same screen changes the details of a document already filed (no suggestions).
struct FilingView: View {
    enum Field: Hashable { case owner, category, ledger, documentDate, sender, description, bill, reimbursement, vat }

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
    /// Beside the Needs Review list instead of a sheet: no Cancel, no window title of its own.
    var embedded = false
    /// A filed document whose details are being changed.
    var editing: DocumentRecord?
    var onDone: () -> Void

    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.modelContext) private var modelContext
    @Query private var ruleRecords: [FilingRuleRecord]
    @Query private var vatReturns: [VATReturnRecord]

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
    @State private var vat = VATInfo()
    /// The user checked a changed IBAN with the sender (and wants it learned).
    @State private var ibanConfirmed = false
    /// The chosen ledger code; empty for none.
    @State private var ledgerCode = ""

    @State private var suggestion = SuggestionState.waitingForText
    /// Fields filled in by the on-device suggestion, and by a learned rule.
    @State private var suggested: Set<Field> = []
    @State private var fromRule: Set<Field> = []
    /// Payment fields for documents that don't look like a bill, on request.
    @State private var showsPayment = false
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
    /// For scans: where each recognised line is, to make the filed PDF searchable.
    @State private var recognizedLines: [[RecognizedLine]]?
    @State private var ocrFailed = false
    @State private var isFiling = false
    /// The Needs Review file the user asked to delete (waits for confirmation).
    @State private var deletingQueued: URL?
    @Environment(AppModel.self) private var model
    @State private var errorMessage: String?

    private var request: FilingRequest {
        var request = FilingRequest(
            owner: ownerName, category: categoryName, receivedDate: receivedDate,
            documentDate: hasDocumentDate ? documentDate : nil, sender: sender, description: descriptionText,
            bill: bill, reimbursedBy: reimbursedBy.isEmpty || reimbursedBy == ownerName ? nil : reimbursedBy,
            vat: showsVAT && !vat.isEmpty ? vat : nil, ledger: chosenLedger
        )
        request.offersLedgerCodes = !ledgerCodes.isEmpty
        if case .changed = ibanCheck { request.ibanChanged = true }
        request.ibanConfirmed = ibanConfirmed
        return request
    }

    // MARK: IBAN check

    /// The pay-to IBAN against the IBANs known for this sender (by the name in the form).
    private var ibanCheck: IBANCheck {
        guard isUnpaidBill else { return .nothingKnown }
        let rules = ruleRecords.map(\.rule)
        return SenderRules.checkIBAN(iban, rule: SenderRules.rule(forSender: sender, in: rules) ?? appliedRule)
    }

    @ViewBuilder
    private var ibanWarning: some View {
        if case .changed(let known) = ibanCheck {
            VStack(alignment: .leading, spacing: 8) {
                Label("New IBAN for \(sender)", systemImage: "exclamationmark.shield.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text("Earlier bills from \(sender) were paid to \(known.map(IBAN.formatted).joined(separator: ", ")). Fraudsters often send a familiar-looking invoice with only the IBAN changed. Before paying, check the new account with \(sender) using a phone number or website you already know, not the details on this invoice.")
                    .font(.callout)
                Toggle("I checked this IBAN with \(sender)", isOn: $ibanConfirmed)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Ledger code

    /// The company that reimburses this expense, if any.
    private var reimbursingCompany: String? {
        reimbursedBy.isEmpty || reimbursedBy == ownerName ? nil : reimbursedBy
    }

    /// The company that books the document: the one that reimburses it, else its owner.
    private var bookingOwner: String {
        ArchiveSettings.bookingOwner(owner: ownerName, reimbursedBy: reimbursingCompany)
    }

    /// The booking company's codes when the chosen category uses ledger codes; else empty.
    private var ledgerCodes: [LedgerCode] {
        settingsStore.settings.ledgerCodes(owner: bookingOwner, category: categoryName)
    }

    /// For a company's document paid privately: the owner to file it under instead (the owner
    /// marked Personal in Settings, e.g. Private).
    private var privateOwner: Owner? {
        guard let currentOwner, !currentOwner.isPersonal, reimbursingCompany == nil else { return nil }
        return settingsStore.settings.owners.first { $0.isPersonal }
    }

    /// Files the document under the private owner, to be reimbursed by the company it showed.
    private func markPaidPrivately(by owner: Owner) {
        let company = ownerName
        ownerName = owner.name
        reimbursedBy = company
        edited.formUnion([.owner, .reimbursement])
    }

    /// The document's own code when editing, kept even if it's no longer in the list.
    private var originalLedger: LedgerCode? {
        guard let editing, !editing.ledgerCode.isEmpty else { return nil }
        return LedgerCode(code: editing.ledgerCode, description: editing.ledgerDescription)
    }

    private var chosenLedger: LedgerCode? {
        guard !ledgerCode.isEmpty else { return nil }
        if let current = ledgerCodes.first(where: { $0.matches(ledgerCode) }) { return current }
        if let originalLedger, originalLedger.matches(ledgerCode) { return originalLedger }
        return LedgerCode(code: ledgerCode)
    }

    private var showsLedger: Bool { !ledgerCodes.isEmpty || !ledgerCode.isEmpty }

    /// What decides the ledger code suggestion: when it changes, the code is checked again.
    private struct LedgerKey: Hashable {
        var owner: String
        var category: String
        var suggestionsFinished: Bool
    }

    private var ledgerKey: LedgerKey {
        let finished = switch suggestion {
        case .waitingForText, .working: false
        case .done, .unavailable, .failed: true
        }
        return LedgerKey(owner: bookingOwner, category: categoryName, suggestionsFinished: finished)
    }

    /// After owner or category changed: drop a code that isn't in the new list, then fill in
    /// the sender's learned code, or ask the on-device model to pick one from the list.
    private func refreshLedger() async {
        let codes = ledgerCodes
        if !ledgerCode.isEmpty, !codes.contains(where: { $0.matches(ledgerCode) }), originalLedger?.matches(ledgerCode) != true {
            ledgerCode = ""
            edited.remove(.ledger)
        }
        guard editing == nil, ledgerCode.isEmpty, !edited.contains(.ledger), !codes.isEmpty else { return }
        suggested.remove(.ledger)
        fromRule.remove(.ledger)
        if let learned = appliedRule?.ledgerCode(owner: bookingOwner),
           let code = codes.first(where: { $0.matches(learned) }) {
            ledgerCode = code.code
            fromRule.insert(.ledger)
            return
        }
        guard ledgerKey.suggestionsFinished, let text = extractedText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ModelExtractor.availability == .available else { return }
        let key = ledgerKey
        let suggester = LedgerCodeSuggester(codes: codes, category: categoryName)
        guard let code = try? await suggester.suggest(sender: sender, description: descriptionText, text: text) else { return }
        // Owner or category changed, or the user chose a code, while the model was working.
        guard !Task.isCancelled, key == ledgerKey, ledgerCode.isEmpty, !edited.contains(.ledger) else { return }
        ledgerCode = code.code
        suggested.insert(.ledger)
    }

    /// VAT shows for owners that track it, and when editing a document that already has VAT
    /// (so saving never drops VAT that was entered before).
    private var showsVAT: Bool { tracksVAT || editing?.vatInfo != nil }

    /// VAT matters when the owner files VAT returns, or a company that does reimburses the expense.
    private var tracksVAT: Bool {
        settingsStore.settings.owners.contains { ($0.name == ownerName || $0.name == reimbursedBy) && $0.vatPeriod != nil }
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

    // MARK: Editing a filed document

    /// The expense is in a submitted (or reimbursed) claim: its company and amount stay as claimed.
    private var claimLocked: Bool {
        guard let editing else { return false }
        return editing.claimState == .submitted || editing.claimState == .reimbursed
    }

    /// The document counts in a VAT return marked as submitted: owner, dates, amount and VAT
    /// stay as submitted. Undo Submitted in the VAT overview to change them.
    private var vatLocked: Bool {
        guard let editing else { return false }
        let returns = vatReturns.map { DocumentEdit.SubmittedReturn(owner: $0.ownerName, start: $0.periodStart, end: $0.periodEnd) }
        return DocumentEdit.isInSubmittedVATReturn(owner: editing.ownerName, reimbursedBy: editing.reimbursedBy, vatDate: editing.vatDate, returns: returns)
    }

    private var amountLocked: Bool { claimLocked || vatLocked }

    private func prefill(from record: DocumentRecord) {
        ownerName = record.ownerName
        categoryName = record.categoryName
        receivedDate = record.receivedDate
        hasDocumentDate = record.documentDate != nil
        documentDate = record.documentDate ?? record.receivedDate
        sender = record.sender
        descriptionText = record.documentDescription
        isUnpaidBill = record.isUnpaidBill
        amount = record.amount
        hasDueDate = record.dueDate != nil
        dueDate = record.dueDate ?? .now
        iban = record.iban ?? ""
        paymentReference = record.paymentReference ?? ""
        reimbursedBy = record.reimbursedBy ?? ""
        vat = record.vatInfo ?? VATInfo()
        ledgerCode = record.ledgerCode
        ibanConfirmed = false
        extractedText = record.extractedText ?? ""
        suggestion = .done
    }

    private var previewPath: String? {
        try? FilingPlanner.plan(for: request, namer: filingService.namer).relativePath
    }

    private func form(showsPDF: Bool) -> some View {
        Form {
            if showsPDF {
                Section {
                    PDFPreview(data: document.pdfData)
                        .frame(minHeight: 260)
                }
            }

            if editing == nil {
                suggestionSection
            } else {
                lockNotice
            }

            Section("Where") {
                HStack {
                    Picker("Owner", selection: tracked($ownerName, .owner)) {
                        ForEach(settingsStore.settings.owners) { Text($0.name).tag($0.name) }
                        // A filed document may use an owner since removed from Settings.
                        if !ownerName.isEmpty, !settingsStore.settings.owners.contains(where: { $0.name == ownerName }) {
                            Text(ownerName).tag(ownerName)
                        }
                    }
                    .disabled(vatLocked)
                    mark(.owner)
                }
                HStack {
                    Picker("Category", selection: tracked($categoryName, .category)) {
                        ForEach(settingsStore.settings.categories) { Text($0.name).tag($0.name) }
                        if !categoryName.isEmpty, !settingsStore.settings.categories.contains(where: { $0.name == categoryName }) {
                            Text(categoryName).tag(categoryName)
                        }
                    }
                    mark(.category)
                }
                if let privateOwner {
                    Button("Paid Privately – Claim from \(ownerName)", systemImage: "person.crop.circle.badge.checkmark") {
                        markPaidPrivately(by: privateOwner)
                    }
                    .disabled(vatLocked || claimLocked)
                    .help(Text("Files it under \(privateOwner.name) as an expense \(ownerName) reimburses. Its VAT and ledger code stay with \(ownerName)."))
                }
                if showsLedger {
                    HStack {
                        Picker("Ledger code", selection: tracked($ledgerCode, .ledger)) {
                            Text("None").tag("")
                            ForEach(ledgerCodes) { Text($0.label).tag($0.code) }
                            // A filed document may use a code since removed from the list.
                            if let chosen = chosenLedger, !ledgerCodes.contains(where: { $0.matches(chosen.code) }) {
                                Text(chosen.label).tag(ledgerCode)
                            }
                        }
                        mark(.ledger)
                    }
                }
            }

            Section("Details") {
                DatePicker("Received", selection: $receivedDate, displayedComponents: .date)
                    .disabled(vatLocked)
                Toggle("Date on document", isOn: tracked($hasDocumentDate, .documentDate))
                    .disabled(vatLocked)
                if hasDocumentDate {
                    HStack {
                        DatePicker("Document date", selection: tracked($documentDate, .documentDate), displayedComponents: .date)
                        mark(.documentDate)
                    }
                    .disabled(vatLocked)
                }
                HStack {
                    TextField("Sender", text: tracked($sender, .sender), prompt: Text("e.g. Acme Energy"))
                    mark(.sender)
                }
                HStack {
                    TextField("Description", text: tracked($descriptionText, .description), prompt: Text("At most 6 words"))
                    mark(.description)
                }
            }

            if showsPaymentFields {
                Section {
                    HStack {
                        Toggle("Unpaid bill", isOn: tracked($isUnpaidBill, .bill))
                        mark(.bill)
                    }
                    TextField("Amount", value: tracked($amount, .bill), format: .currency(code: "EUR"), prompt: Text("€ 0.00"))
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .disabled(amountLocked)
                    if isUnpaidBill {
                        Toggle("Due date", isOn: tracked($hasDueDate, .bill))
                        if hasDueDate {
                            DatePicker("Pay before", selection: tracked($dueDate, .bill), displayedComponents: .date)
                        }
                        TextField("IBAN", text: tracked($iban, .bill), prompt: Text("NL00 BANK 0123 4567 89"))
                            .autocorrectionDisabled()
                        ibanWarning
                        TextField("Payment reference", text: tracked($paymentReference, .bill))
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Payment")
                } footer: {
                    if isUnpaidBill {
                        Text("Paper Trail adds a reminder to the To pay list of this owner in Reminders.")
                    }
                }
            } else {
                Section {
                    Button("Add Amount or Payment Details", systemImage: "eurosign.circle") { showsPayment = true }
                }
            }

            if showsExpense {
                Section {
                    HStack {
                        Picker("To be reimbursed by", selection: tracked($reimbursedBy, .reimbursement)) {
                            Text("Nobody").tag("")
                            ForEach(settingsStore.settings.owners.filter { $0.name != ownerName }) { Text($0.name).tag($0.name) }
                        }
                        mark(.reimbursement)
                    }
                    .disabled(claimLocked)
                } header: {
                    Text("Expense")
                } footer: {
                    Text("For a personal expense a company pays back. It appears under Expenses until it's claimed and reimbursed.")
                }
            }

            if showsVAT {
                Section {
                    VATEditor(vat: tracked($vat, .vat))
                        .disabled(vatLocked)
                } header: {
                    Text("VAT")
                } footer: {
                    Text(vat.lines.isEmpty ? "No VAT line found in the text. Add one if the document shows VAT." : "Found in the document's text. Check rate and amounts.")
                }
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

            if let queued = document.reviewItemURL, editing == nil {
                Section {
                    Button("Delete from Needs Review", systemImage: "trash", role: .destructive) { deletingQueued = queued }
                        .disabled(isFiling)
                } footer: {
                    Text("For a duplicate or something you don't need to keep. It goes to the Trash.")
                }
            }

            if document.reviewItemURL == nil, editing == nil {
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
        .keyboardDismissal()
    }

    private var currentOwner: Owner? { settingsStore.settings.owners.first { $0.name == ownerName } }

    /// Expenses are personal documents a company pays back; for a company's own documents the
    /// section only shows when already set.
    private var showsExpense: Bool { !reimbursedBy.isEmpty || currentOwner?.isPersonal == true }

    private var showsPaymentFields: Bool { showsPayment || isUnpaidBill || amount != nil }

    /// A sparkle for a suggested value, a branch for one from a learned rule; nothing once edited.
    @ViewBuilder
    private func mark(_ field: Field) -> some View {
        if !edited.contains(field) {
            if fromRule.contains(field), let rule = appliedRule {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.tint)
                    .help(Text("From your rule for \(rule.senderName)"))
                    .accessibilityLabel(Text("From your rule for \(rule.senderName)"))
            } else if suggested.contains(field) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                    .help(Text("Suggested on this device"))
                    .accessibilityLabel(Text("Suggested on this device"))
            }
        }
    }

    var body: some View {
        // Wide enough (Mac, iPad, a big phone sideways): the PDF beside the fields; else on top.
        GeometryReader { geometry in
            if geometry.size.width >= 640 {
                HStack(spacing: 0) {
                    PDFPreview(data: document.pdfData)
                        .frame(width: max(260, geometry.size.width * 0.45))
                    Divider()
                    form(showsPDF: false)
                }
            } else {
                form(showsPDF: true)
            }
        }
        .titleUnlessEmbedded(embedded, editing == nil ? String(localized: "File document") : String(localized: "Edit Details"))
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDone)
                        .disabled(isFiling)
                }
            }
            if !usesActionBar {
                ToolbarItem(placement: .confirmationAction) {
                    if isFiling {
                        ProgressView()
                    } else {
                        Button(editing == nil ? "File" : "Save") { Task { await checkAndFile() } }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(previewPath == nil)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if usesActionBar { actionBar }
        }
        .alert(editing == nil ? "Could not file the document" : "Could not save the changes", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Delete this document from Needs Review?", isPresented: Binding(get: { deletingQueued != nil }, set: { if !$0 { deletingQueued = nil } }),
                            titleVisibility: .visible, presenting: deletingQueued) { url in
            Button("Move to Trash", role: .destructive) {
                Task { if await model.deleteReviewItem(at: url) { onDone() } }
            }
        } message: { _ in
            Text("You can get it back from the Trash (Recently Deleted in Files).")
        }
        .alert("Already filed?", isPresented: Binding(get: { duplicate != nil }, set: { if !$0 { duplicate = nil } }), presenting: duplicate) { _ in
            Button("File Anyway") { Task { await file() } }
            if let queued = document.reviewItemURL {
                // Already a question; the copy goes to the Trash, so no second one.
                Button("Delete This Copy", role: .destructive) {
                    Task { if await model.deleteReviewItem(at: queued) { onDone() } }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { match in
            Text("\(match.reason.message) An earlier document is in your archive:\n\(match.existing.relativePath)")
        }
        .alert(editing == nil ? "Filed, but something needs attention" : "Saved, but the reminder wasn't updated", isPresented: Binding(get: { reminderProblem != nil }, set: { if !$0 { reminderProblem = nil; onDone() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(reminderProblem ?? "")
        }
        .interactiveDismissDisabled(isFiling)
        .onAppear {
            if let editing { prefill(from: editing) } else { applyDefaults() }
        }
        .task { if editing == nil { await recognizeText() } }
        .task(id: ledgerKey) { await refreshLedger() }
    }

    /// On the Mac, and beside the review list on iPad, a toolbar button is easy to miss: the
    /// main action gets a large button at the bottom, with where the document will go.
    private var usesActionBar: Bool {
        #if os(macOS)
        true
        #else
        embedded
        #endif
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            if let previewPath {
                Label {
                    Text(previewPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "folder")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .help(previewPath)
            } else {
                Text("Choose an owner and a category.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isFiling { ProgressView().controlSize(.small) }
            Button {
                Task { await checkAndFile() }
            } label: {
                Label(editing == nil ? "File Document" : "Save Changes",
                      systemImage: editing == nil ? "tray.and.arrow.down.fill" : "checkmark")
                    .padding(.horizontal, 6)
                    .lineLimit(1)
            }
            // The button keeps its full label; the path above gives way.
            .fixedSize()
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(previewPath == nil || isFiling)
            .help(editing == nil ? "File Document (⌘↩)" : "Save Changes (⌘↩)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var lockNotice: some View {
        if vatLocked {
            Section {
                Label("This document is in a VAT return marked as submitted. Its owner, dates, amount and VAT can't be changed; use Undo Submitted in the VAT overview first.", systemImage: "lock")
                    .foregroundStyle(.secondary)
            }
        } else if claimLocked {
            Section {
                Label("This expense is in a submitted claim. Its amount and company can't be changed; undo the claim under Expenses first.", systemImage: "lock")
                    .foregroundStyle(.secondary)
            }
        }
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
            let result = document.pageImages.isEmpty
                ? try await PDFTextExtractor(recognizer: recognizer).extract(from: document.pdfData)
                : try await recognizer.recognizeText(in: document.pageImages)
            extractedText = result.text
            recognizedLines = result.lines
        } catch is CancellationError {
            return
        } catch {
            ocrFailed = true
            suggestion = .failed
            return
        }
        applyRule()
        suggestVAT()
        await suggestDetails()
        suggestVAT()
    }

    /// VAT lines from the text; read again once the total amount is known.
    private func suggestVAT() {
        guard !edited.contains(.vat), let text = extractedText else { return }
        vat = VATExtractor.extract(from: text, total: amount)
    }

    /// Learned rules run before the model, and also work when the model is unavailable.
    private func applyRule() {
        guard let text = extractedText,
              let rule = SenderRules.match(ruleRecords.map(\.rule), text: text) else { return }
        appliedRule = rule
        fromRule = [.owner, .category, .sender]
        if rule.reimbursedBy != nil { fromRule.insert(.reimbursement) }
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
        suggested.formUnion([.description, .documentDate, .bill])
        if !ruleWins { suggested.formUnion([.category, .sender]) }
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
        if let editing {
            await saveEdits(editing)
            return
        }
        if let match = try? filingService.duplicates(of: document, request: request, context: modelContext).first {
            duplicate = match
            return
        }
        await file()
    }

    /// Moves or renames the file if needed, updates the index, then the bill's reminder.
    private func saveEdits(_ record: DocumentRecord) async {
        isFiling = true
        defer { isFiling = false }
        let before = record.reminderFacts
        let wasUnpaidBill = record.isUnpaidBill
        let hadReminder = record.reminderExternalID != nil
        do {
            try await filingService.update(record, request: request, context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let change = DocumentEdit.reminderChange(before: before, after: record.reminderFacts, wasUnpaidBill: wasUnpaidBill,
                                                 isUnpaidBill: record.isUnpaidBill, isPaid: record.isPaid, hasReminder: hadReminder)
        do {
            try await billService.updateReminder(for: record, change: change, createsReminders: settingsStore.settings.createsBillReminders,
                                                 context: modelContext)
        } catch {
            // The changes are saved; only the reminder is out of date.
            reminderProblem = error.localizedDescription
            return
        }
        onDone()
    }

    private func file() async {
        isFiling = true
        defer { isFiling = false }
        do {
            let record = try await filingService.file(document, request: request, extractedText: extractedText, textLayer: recognizedLines,
                                                      suggestedSender: suggestedSender, context: modelContext)
            // The document is safely filed from here on; problems after this are only reported.
            var problems: [String] = []
            if let queued = document.reviewItemURL, FileManager.default.fileExists(atPath: queued.path(percentEncoded: false)) {
                problems.append(String(localized: "Its copy in Needs Review could not be removed. Delete it there, so it isn't filed twice."))
            }
            do {
                if settingsStore.settings.createsBillReminders {
                    try await billService.addReminder(for: record, context: modelContext)
                }
            } catch {
                problems.append(error.localizedDescription)
            }
            if problems.isEmpty {
                onDone()
            } else {
                reminderProblem = problems.joined(separator: "\n\n")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
