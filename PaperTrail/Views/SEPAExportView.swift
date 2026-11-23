import PaperTrailKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The SEPA batch file handed to the save panel.
nonisolated struct SEPAFile: FileDocument {
    static let readableContentTypes: [UTType] = [.xml]
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Pick open bills of one owner and save them as a SEPA batch file to upload in business
/// internet banking. Exporting does not mark anything paid.
struct SEPAExportView: View {
    let owner: Owner
    let bills: [DocumentRecord]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var executionDate = Date.now
    @State private var file: SEPAFile?
    @State private var errorMessage: String?

    private static func payment(for bill: DocumentRecord) -> SEPAPayment {
        SEPAPayment(
            creditorName: bill.sender, creditorIBAN: bill.iban ?? "", amount: bill.amount ?? 0,
            reference: bill.paymentReference ?? "",
            endToEndID: "PT-" + bill.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(32)
        )
    }

    private func problem(_ bill: DocumentRecord) -> String? {
        switch SEPACreditTransfer.problem(with: Self.payment(for: bill)) {
        case nil: nil
        case .invalidCreditorIBAN: String(localized: "IBAN missing or not valid")
        case .missingCreditorName: String(localized: "Sender missing")
        case .invalidAmount: String(localized: "Amount missing")
        default: String(localized: "Can't be paid by file")
        }
    }

    private var chosen: [DocumentRecord] { bills.filter { selected.contains($0.id) && problem($0) == nil } }

    private var total: Double { chosen.compactMap(\.amount).reduce(0, +) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(bills) { bill in
                        let issue = problem(bill)
                        Toggle(isOn: Binding(
                            get: { selected.contains(bill.id) && issue == nil },
                            set: { if $0 { selected.insert(bill.id) } else { selected.remove(bill.id) } }
                        )) {
                            VStack(alignment: .leading) {
                                Text(bill.sender)
                                if let issue {
                                    Text(issue).font(.caption).foregroundStyle(.red)
                                } else if let exported = bill.exportedAt {
                                    Text("Already exported \(exported.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            if let amount = bill.amount { Text(BillReminderText.amount(amount)) }
                        }
                        .disabled(issue != nil)
                    }
                } header: {
                    Text("Bills")
                } footer: {
                    Text("\(chosen.count) payments, total \(BillReminderText.amount(total)), from \(IBAN.formatted(owner.payingAccount.iban)).")
                }

                Section {
                    DatePicker("Pay on", selection: $executionDate, in: Calendar.current.startOfDay(for: .now)..., displayedComponents: .date)
                } footer: {
                    Text("Upload the file in your bank's business internet banking, check the payments there and sign. Nothing is paid until you sign at the bank. Bills stay open until their reminder is completed.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("SEPA file for \(owner.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") { export() }.disabled(chosen.isEmpty)
                }
            }
            .fileExporter(isPresented: Binding(get: { file != nil }, set: { if !$0 { file = nil } }), document: file,
                          contentType: .xml, defaultFilename: fileName) { result in
                switch result {
                case .success:
                    for bill in chosen { bill.exportedAt = .now }
                    do {
                        try modelContext.save()
                    } catch {
                        errorMessage = String(localized: "The file was saved, but Paper Trail could not note the export: \(error.localizedDescription)")
                        return
                    }
                    dismiss()
                case .failure(let error):
                    errorMessage = String(localized: "Could not save the file: \(error.localizedDescription) Try another folder.")
                }
            }
            .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                // Preselect bills that can be paid and were not exported before.
                selected = Set(bills.filter { problem($0) == nil && $0.exportedAt == nil }.map(\.id))
            }
        }
    }

    private var fileName: String {
        let stamp = Date.now.formatted(.iso8601.year().month().day())
        return "\(FileNamer.sanitizeComponent(owner.name)) SEPA \(stamp).xml"
    }

    private func export() {
        let now = Date.now
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: now)
        // Unique per file: banks reject a batch whose message ID they have seen before.
        let messageID = String(format: "PT-%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        do {
            let xml = try SEPACreditTransfer.xml(
                messageID: messageID, created: now, executionDate: executionDate,
                debtor: owner.payingAccount, payments: chosen.map(Self.payment(for:))
            )
            file = SEPAFile(text: xml)
        } catch {
            errorMessage = String(localized: "Could not make the SEPA file. Check the paying account for \(owner.name) in Settings and the details of each bill. (\(String(describing: error)))")
        }
    }
}
