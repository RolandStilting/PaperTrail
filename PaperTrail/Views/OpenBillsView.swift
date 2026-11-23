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

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settingsStore
    @Query(filter: #Predicate<DocumentRecord> { $0.isUnpaidBill && !$0.isPaid }, sort: \DocumentRecord.receivedDate)
    private var bills: [DocumentRecord]
    @State private var path: [UUID] = []
    @State private var exportingOwner: Owner?

    private var owners: [String] {
        let configured = settingsStore.settings.owners.map(\.name)
        let used = Set(bills.map(\.ownerName))
        return configured.filter(used.contains) + used.subtracting(configured).sorted()
    }

    private func bills(of owner: String) -> [DocumentRecord] {
        bills.filter { $0.ownerName == owner }
            .sorted { ($0.dueDate ?? .distantFuture, $0.receivedDate) < ($1.dueDate ?? .distantFuture, $1.receivedDate) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if bills.isEmpty {
                    ContentUnavailableView("No open bills", systemImage: "checkmark.seal", description: Text("Unpaid bills you file show up here until their reminder is completed."))
                }
                ForEach(owners, id: \.self) { owner in
                    Section(owner) {
                        ForEach(bills(of: owner)) { bill in
                            NavigationLink(value: bill.id) { BillRow(bill: bill) }
                        }
                        if let settings = settingsStore.settings.owners.first(where: { $0.name == owner }), settings.paymentMethod == .sepaFile {
                            Button("Export SEPA File…", systemImage: "square.and.arrow.up") { exportingOwner = settings }
                        }
                    }
                }
            }
            .navigationTitle("Open Bills")
            .navigationDestination(for: UUID.self) { id in
                if let bill = bills.first(where: { $0.id == id }) {
                    BillDetailView(bill: bill, billService: billService)
                } else {
                    ContentUnavailableView("Bill paid", systemImage: "checkmark.seal")
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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

    @Environment(\.modelContext) private var modelContext
    @State private var errorMessage: String?
    @State private var confirmingPaid = false
    @State private var copied: String?
    @State private var isWorking = false

    private var qrPayload: Result<String, EPCQRCode.PayloadError> {
        Result { () throws(EPCQRCode.PayloadError) -> String in
            try EPCQRCode.payload(name: bill.sender, iban: bill.iban ?? "", amount: bill.amount, reference: bill.paymentReference ?? "")
        }
    }

    var body: some View {
        Form {
            Section {
                switch qrPayload {
                case .success(let payload):
                    PaymentQRCode(payload: payload)
                        .frame(maxWidth: 320, maxHeight: 320)
                        .frame(maxWidth: .infinity)
                case .failure(let error):
                    Label(Self.message(for: error), systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Scan with your banking app, check the details and confirm there. Paper Trail never sends payments.")
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
                }
                Button("Mark as Paid", systemImage: "checkmark.circle") { confirmingPaid = true }
                    .disabled(isWorking)
            } footer: {
                Text("Completing the bill's reminder in Reminders also marks it paid.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(bill.sender)
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

    private func markPaid() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await billService.markPaid(bill, context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
