import PaperTrailKit
import SwiftData
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Unpaid bills per owner. Paying happens in the banking app; this screen helps with the
/// details. A bill is paid when its reminder is completed or it is marked paid here.
struct OpenBillsView: View {
    let billService: BillService
    /// Bill to open straight away, e.g. from a reminder's link.
    var initialBillID: UUID?
    /// Inside the app's navigation (tab or sidebar) instead of a sheet.
    var embedded = false

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settingsStore
    @Query(filter: #Predicate<DocumentRecord> { $0.isUnpaidBill && !$0.isPaid }, sort: \DocumentRecord.receivedDate)
    private var bills: [DocumentRecord]
    @State private var path: [UUID] = []
    @State private var exportingOwner: Owner?
    @State private var selection: UUID?

    private var owners: [String] {
        let configured = settingsStore.settings.owners.map(\.name)
        let used = Set(bills.map(\.ownerName))
        return configured.filter(used.contains) + used.subtracting(configured).sorted()
    }

    private func bills(of owner: String) -> [DocumentRecord] {
        bills.filter { $0.ownerName == owner }
            .sorted { ($0.dueDate ?? .distantFuture, $0.receivedDate) < ($1.dueDate ?? .distantFuture, $1.receivedDate) }
    }

    /// Bills in the order the list shows them, for the arrow keys.
    private var orderedIDs: [UUID] { owners.flatMap { bills(of: $0).map(\.id) } }

    var body: some View {
        SheetNavigation(embedded: embedded, path: $path) {
            Group {
                if embedded {
                    // Mac and iPad: the selected bill's QR code and details beside the list.
                    ListWithDetail { split in
                        billList(split: split)
                    } detail: {
                        if let selection, let bill = bills.first(where: { $0.id == selection }) {
                            BillDetailView(bill: bill, billService: billService, embedded: true)
                                .id(bill.id)
                        } else {
                            ContentUnavailableView(bills.isEmpty ? "No open bills" : "Select a bill",
                                                   systemImage: bills.isEmpty ? "checkmark.seal" : "qrcode",
                                                   description: Text(bills.isEmpty ? "Everything is paid." : "Its QR code and payment details appear here."))
                        }
                    }
                } else {
                    billList(split: false)
                }
            }
            .navigationTitle("To Pay")
            .navigationDestination(for: UUID.self) { id in
                if let bill = bills.first(where: { $0.id == id }) {
                    BillDetailView(bill: bill, billService: billService)
                } else {
                    ContentUnavailableView("Bill paid", systemImage: "checkmark.seal")
                }
            }
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .sheet(item: $exportingOwner) { owner in
                SEPAExportView(owner: owner, bills: bills(of: owner.name))
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 520)
                #endif
            }
        }
        .onAppear {
            if let initialBillID, path.isEmpty { path = [initialBillID] }
        }
    }

    private func billList(split: Bool) -> some View {
        Group {
            // Only the split layout selects. In a selectable list the selection would take the
            // tap meant for the row's link (both are bill IDs), so on a phone nothing opened.
            if split {
                List(selection: $selection) { billRows(split: true) }
            } else {
                List { billRows(split: false) }
            }
        }
        .arrowKeySelection($selection, in: orderedIDs)
        .onAppear { if split, selection == nil { selection = orderedIDs.first } }
        .onChange(of: orderedIDs) { _, ids in
            // A bill marked paid leaves the list: select the next one.
            if split, let selection, !ids.contains(selection) { self.selection = ids.first }
        }
    }

    @ViewBuilder
    private func billRows(split: Bool) -> some View {
        if bills.isEmpty {
            ContentUnavailableView("No open bills", systemImage: "checkmark.seal", description: Text("Unpaid bills you file show up here until their reminder is completed."))
        }
        ForEach(owners, id: \.self) { owner in
            Section(owner) {
                ForEach(bills(of: owner)) { bill in
                    Group {
                        if split {
                            BillRow(bill: bill)
                        } else {
                            // A direct link: this list is often pushed by another link (Money,
                            // Today), where a value link finds no destination and does nothing.
                            NavigationLink { BillDetailView(bill: bill, billService: billService) } label: { BillRow(bill: bill) }
                        }
                    }
                    .tag(bill.id)
                }
                if let settings = settingsStore.settings.owners.first(where: { $0.name == owner }), settings.paymentMethod == .sepaFile {
                    Button("Export SEPA File…", systemImage: "square.and.arrow.up") { exportingOwner = settings }
                }
            }
        }
    }
}

private struct BillRow: View {
    let bill: DocumentRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(bill.sender).font(.headline)
                if let due = bill.dueDate {
                    Text("Due \(due.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(due < Calendar.current.startOfDay(for: .now) ? .red : .secondary)
                }
            }
            Spacer()
            if bill.ibanUnconfirmed {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.red)
                    .help("New IBAN, not checked yet")
                    .accessibilityLabel(Text("New IBAN, not checked yet"))
            }
            if bill.exportedAt != nil {
                Image(systemName: "square.and.arrow.up.circle")
                    .foregroundStyle(.orange)
                    .help("Exported in a SEPA file; open until its reminder is completed")
                    .accessibilityLabel(Text("Exported"))
            }
            if let amount = bill.amount {
                Text(BillReminderText.amount(amount)).monospacedDigit()
            }
        }
    }
}

struct BillDetailView: View {
    let bill: DocumentRecord
    let billService: BillService
    /// Beside the To Pay list: the list keeps the window title.
    var embedded = false

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(AppModel.self) private var model
    @Environment(SettingsStore.self) private var settingsStore
    @State private var errorMessage: String?
    @State private var scanProblem: String?
    @State private var isScanning = false
    @State private var confirmingPaid = false
    @State private var copied: String?
    @State private var isWorking = false
    @State private var reminderMissing = false
    @Query private var ruleRecords: [FilingRuleRecord]
    /// The payment page waiting for the user's OK before it opens.
    @State private var pendingLink: URL?
    @State private var confirmingIBAN = false

    /// The learned rule for this bill's sender, if any.
    private var senderRule: FilingRuleRecord? {
        guard let rule = SenderRules.rule(forSender: bill.sender, in: ruleRecords.map(\.rule)) else { return nil }
        return ruleRecords.first { $0.id == rule.id }
    }

    private var hostCheck: PaymentHostCheck {
        guard let host = bill.paymentCode?.host else { return .nothingKnown }
        return SenderRules.checkPaymentHost(host, rule: senderRule?.rule)
    }

    /// Remembers the payment page's host for this sender once the user accepted it.
    private func acceptPaymentHost() {
        guard let host = bill.paymentCode?.host, let record = senderRule else { return }
        record.update(from: SenderRules.accepting(paymentHost: host, in: record.rule))
        try? modelContext.save()
    }

    private func confirmIBAN() {
        bill.ibanUnconfirmed = false
        if let record = senderRule, let iban = bill.iban {
            record.update(from: SenderRules.confirming(iban: iban, in: record.rule))
        }
        do { try modelContext.save() } catch { errorMessage = error.localizedDescription }
    }

    @ViewBuilder
    private var ibanWarning: some View {
        if bill.ibanUnconfirmed {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("New IBAN – not checked yet", systemImage: "exclamationmark.shield.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text("Earlier bills from \(bill.sender) were paid to another account. Fraudsters often send a familiar-looking invoice with only the IBAN changed. Check the new account with \(bill.sender) using a phone number or website you already know, not the details on this invoice.")
                        .font(.callout)
                    Button("I Checked This IBAN", systemImage: "checkmark.shield") { confirmingIBAN = true }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var qrPayload: Result<String, EPCQRCode.PayloadError> {
        Result { () throws(EPCQRCode.PayloadError) -> String in
            try EPCQRCode.payload(name: bill.sender, iban: bill.iban ?? "", amount: bill.amount, reference: bill.paymentReference ?? "")
        }
    }

    var body: some View {
        Form {
            ibanWarning
            if embedded {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(bill.sender).font(.title2.weight(.semibold))
                        if let amount = bill.amount {
                            Text(BillReminderText.amount(amount)).font(.title3).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                paymentCodeContent
            } footer: {
                switch bill.paymentCode?.source {
                case .qrCode: Text("From the invoice itself: scan the code with your banking app, check the details and confirm there. Paper Trail never sends payments.")
                case .link: Text("From the invoice itself: the sender's payment page. Check the details there before you pay. Paper Trail never sends payments.")
                case nil: Text("Scan with your banking app, check the details and confirm there. Paper Trail never sends payments.")
                }
            }

            Section("Details") {
                copyRow("Pay to", bill.sender)
                if let iban = bill.iban, !iban.isEmpty { copyRow("IBAN", IBAN.formatted(iban), copyValue: iban) }
                if let amount = bill.amount {
                    copyRow("Amount", BillReminderText.amount(amount), copyValue: String(format: "%.2f", amount).replacingOccurrences(of: ".", with: Locale.current.decimalSeparator ?? ","))
                }
                if let reference = bill.paymentReference, !reference.isEmpty { copyRow("Reference", reference) }
                if let due = bill.dueDate { LabeledContent("Due", value: due.formatted(date: .long, time: .omitted)) }
                LabeledContent("Document", value: bill.relativePath)
            }

            Section {
                if bill.reminderExternalID == nil {
                    Button("Create Reminder", systemImage: "checklist") { Task { await createReminder() } }
                        .disabled(isWorking)
                } else if reminderMissing, settingsStore.settings.createsBillReminders {
                    Button("Reminder Not Found – Create Again", systemImage: "checklist") { Task { await recreateReminder() } }
                        .disabled(isWorking)
                }
                Button("Mark as Paid", systemImage: "checkmark.circle") { confirmingPaid = true }
                    .disabled(isWorking)
                Button("Look for Payment Code Again", systemImage: "qrcode.viewfinder") { Task { await findPaymentCode(again: true) } }
                    .disabled(isScanning)
            } footer: {
                if bill.reminderExternalID != nil {
                    Text("Completing the bill's reminder in Reminders also marks it paid.")
                }
            }
        }
        .formStyle(.grouped)
        .titleUnlessEmbedded(embedded, bill.sender)
        .task { reminderMissing = await billService.reminderIsMissing(for: bill) }
        .task(id: bill.id) { await findPaymentCode(again: false) }
        .confirmationDialog("Open \(pendingLink?.host() ?? "")?", isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }),
                            titleVisibility: .visible, presenting: pendingLink) { url in
            Button("Open \(url.host() ?? "")") {
                acceptPaymentHost()
                openURL(url)
            }
        } message: { url in
            Text("This address comes from the invoice: \(url.absoluteString)\n\nOnly continue if it belongs to \(bill.sender) or their payment provider. Check the payee and amount on the page before you pay.")
        }
        .confirmationDialog("Mark the IBAN as checked?", isPresented: $confirmingIBAN, titleVisibility: .visible) {
            Button("I Checked This IBAN") { confirmIBAN() }
        } message: {
            Text("Paper Trail then remembers \(IBAN.formatted(bill.iban ?? "")) as an account of \(bill.sender).")
        }
        .confirmationDialog("Mark this bill as paid?", isPresented: $confirmingPaid) {
            Button("Mark as Paid") { Task { await markPaid() } }
        } message: {
            Text("Its reminder is completed too.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// The owner's banking app accepts Paper Trail's own EPC QR code.
    private var bankScansEPC: Bool {
        settingsStore.settings.owners.first { $0.name == bill.ownerName }?.bankScansEPCQRCode ?? true
    }

    @ViewBuilder
    private var paymentCodeContent: some View {
        if let code = bill.paymentCode {
            if code.source == .qrCode {
                PaymentQRCode(payload: code.payload)
                    .frame(maxWidth: 320, maxHeight: 320)
                    .frame(maxWidth: .infinity)
            }
            if let url = code.url {
                LabeledContent(code.source == .qrCode ? "Code goes to" : "Link goes to") {
                    Text(code.host ?? "").font(.body.monospaced()).textSelection(.enabled)
                }
                if case .new(let known) = hostCheck {
                    Label("Earlier bills from \(bill.sender) used \(known.joined(separator: ", ")). Check that this address belongs to \(bill.sender) or their payment provider before paying.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Button("Open Payment Page", systemImage: "safari") { pendingLink = url }
                    .help(url.absoluteString)
            }
        } else if isScanning {
            ProgressView("Looking for a payment code on the invoice…")
                .frame(maxWidth: .infinity)
        } else if bankScansEPC {
            switch qrPayload {
            case .success(let payload):
                PaymentQRCode(payload: payload)
                    .frame(maxWidth: 320, maxHeight: 320)
                    .frame(maxWidth: .infinity)
            case .failure(let error):
                Label(Self.message(for: error), systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        } else {
            Label("This invoice has no payment code or link. Use the copy buttons below.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        }
        if let scanProblem {
            Label(scanProblem, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    /// Searches the bill's PDF once for a QR code or pay link from the sender; the result is
    /// stored on the record (and synced), so other devices don't search again.
    private func findPaymentCode(again: Bool) async {
        guard again || PaymentCode.needsSearch(checkedAt: bill.paymentCodeCheckedAt, found: bill.paymentCode),
              let url = model.fileURL(for: bill) else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            let result = try await PaymentCodeScanner.scan(fileAt: url, text: bill.extractedText ?? "")
            bill.paymentCode = result.code
            // Without a working QR search, only a found link counts as done; try again next time.
            if result.code != nil || !result.qrSearchFailed { bill.paymentCodeCheckedAt = .now }
            try modelContext.save()
            scanProblem = result.code == nil && result.qrSearchFailed
                ? String(localized: "Couldn't look for QR codes on this device; only links were checked.")
                : nil
        } catch {
            scanProblem = error.localizedDescription
        }
    }

    private func copyRow(_ label: LocalizedStringKey, _ value: String, copyValue: String? = nil) -> some View {
        LabeledContent(label) {
            HStack {
                Text(value).textSelection(.enabled)
                Button(copied == (copyValue ?? value) ? "Copied" : "Copy", systemImage: copied == (copyValue ?? value) ? "checkmark" : "doc.on.doc") {
                    Self.copy(copyValue ?? value)
                    copied = copyValue ?? value
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        }
    }

    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    static func message(for error: EPCQRCode.PayloadError) -> String {
        switch error {
        case .invalidIBAN: String(localized: "No QR code: the IBAN is missing or not valid. Check it on the document and use the copy buttons.")
        case .missingName: String(localized: "No QR code: the sender is missing.")
        case .amountOutOfRange: String(localized: "No QR code: the amount is missing or not valid.")
        }
    }

    private func createReminder() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await billService.addReminder(for: bill, context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func recreateReminder() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await billService.recreateReminder(for: bill, context: modelContext)
            reminderMissing = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func markPaid() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await billService.markPaid(bill, context: modelContext)
            // Paid with the code from the invoice: its address is now one this sender uses
            // (unless a warning was still showing).
            var hostIsNew = false
            if case .new = hostCheck { hostIsNew = true }
            if !bill.ibanUnconfirmed, !hostIsNew { acceptPaymentHost() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
