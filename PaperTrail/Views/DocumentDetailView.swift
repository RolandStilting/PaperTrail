import PaperTrailKit
import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// One filed document: the PDF, its details and what you can do with it.
struct DocumentDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsStore.self) private var settingsStore
    @Query private var matches: [DocumentRecord]
    @State private var pdf: Data?
    @State private var loadFailed = false
    @State private var editingVAT = false

    /// In the archive's document pane: the archive keeps the window title, so the sender is
    /// shown as a heading instead.
    var embedded = false

    init(id: UUID, embedded: Bool = false) {
        self.embedded = embedded
        _matches = Query(filter: #Predicate<DocumentRecord> { $0.id == id })
    }

    var body: some View {
        if let record = matches.first {
            content(record)
        } else {
            ContentUnavailableView("Document not found", systemImage: "doc.questionmark",
                                   description: Text("It may have been removed from the archive."))
        }
    }

    private func content(_ record: DocumentRecord) -> some View {
        Form {
            if embedded {
                Section {
                    Text(record.sender).font(.title2.weight(.semibold))
                }
            }
            Section {
                Group {
                    if let pdf {
                        PDFPreview(data: pdf)
                    } else if loadFailed {
                        ContentUnavailableView("Can't show the PDF", systemImage: "icloud.slash",
                                               description: Text("Check that the file is still in iCloud Drive and downloaded."))
                    } else {
                        ProgressView()
                    }
                }
                .frame(minHeight: 340)
            }

            Section {
                LabeledContent("Filed under") {
                    HStack(spacing: 6) {
                        OwnerDot(owner: record.ownerName)
                        Text(record.ownerName)
                        Text("›").foregroundStyle(.tertiary)
                        Label(record.categoryName, systemImage: CategoryStyle.symbol(for: record.categoryName))
                    }
                    .foregroundStyle(.secondary)
                }
                LabeledContent("Received", value: record.receivedDate.formatted(date: .long, time: .omitted))
                if let date = record.documentDate {
                    LabeledContent("Date on document", value: date.formatted(date: .long, time: .omitted))
                }
                if let amount = record.amount {
                    LabeledContent("Amount", value: BillReminderText.amount(amount))
                }
                if let vat = record.vatInfo, !vat.lines.isEmpty {
                    LabeledContent("VAT", value: vat.lines.map { "\(VATEditor.rateText($0.rate)) \(BillReminderText.amount($0.amount))" }.joined(separator: " + "))
                }
                HStack {
                    Text("Status")
                    Spacer()
                    StatusBadge(record: record)
                }
            } header: {
                Text(record.documentDescription)
            }

            Section("Actions") {
                if record.isOpenBill {
                    NavigationLink {
                        BillDetailView(bill: record, billService: model.billService)
                    } label: {
                        Label("Pay", systemImage: "qrcode")
                    }
                }
                if record.vatInfo != nil || settingsStore.settings.owners.contains(where: { ($0.name == record.ownerName || $0.name == record.reimbursedBy) && $0.vatPeriod != nil }) {
                    Button("Edit VAT", systemImage: "percent") { editingVAT = true }
                }
                ReimbursementMenu(record: record)
                if let url = model.fileURL(for: record) {
                    ShareLink(item: url) { Label("Share PDF", systemImage: "square.and.arrow.up") }
                    #if os(macOS)
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    #endif
                }
            }

            Section {
                Text(record.relativePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text("In iCloud Drive")
            }
        }
        .formStyle(.grouped)
        .titleUnlessEmbedded(embedded, record.sender)
        .sheet(isPresented: $editingVAT) { VATEditSheet(record: record) }
        .task(id: record.relativePath) { await load(record) }
    }

    private func load(_ record: DocumentRecord) async {
        guard let url = model.fileURL(for: record) else { loadFailed = true; return }
        do {
            pdf = try await Task.detached { try InboxCollector.coordinatedRead(url) }.value
        } catch {
            loadFailed = true
        }
    }
}

private extension View {
    /// The document pane leaves the window title to the archive.
    @ViewBuilder
    func titleUnlessEmbedded(_ embedded: Bool, _ title: String) -> some View {
        if embedded { self } else { navigationTitle(title) }
    }
}
