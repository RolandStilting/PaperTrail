import PaperTrailKit
import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Input VAT to reclaim per company and period. Counts only; deductibility is the user's call.
struct VATOverviewView: View {
    /// Inside the app's navigation (tab or sidebar) instead of a sheet.
    var embedded = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settingsStore
    @Query private var documents: [DocumentRecord]
    @Query private var returns: [VATReturnRecord]

    @State private var company = ""
    @State private var period: VATPeriod?
    @State private var editing: DocumentRecord?
    @State private var export: ExportFiles?
    @State private var errorMessage: String?
    @State private var confirmingReadAgain = false

    private var companies: [Owner] { settingsStore.settings.owners.filter { $0.vatPeriod != nil } }

    private var records: [DocumentRecord] {
        guard let period else { return [] }
        return documents.filter { record in
            (record.ownerName == company || record.reimbursedBy == company)
                && period.contains(record.vatDate)
                && (record.vatInfo != nil || (record.amount ?? 0) > 0)
        }
    }

    private var report: VATReport? {
        guard let period else { return nil }
        return VATReport(company: company, period: period, items: records.map { record in
            VATReportItem(date: record.vatDate, sender: record.sender, description: record.documentDescription, amount: record.amount,
                          vat: record.vatInfo ?? VATInfo(), isReimbursedExpense: record.reimbursedBy == company && record.ownerName != company,
                          relativePath: record.relativePath)
        })
    }

    private var submitted: VATReturnRecord? {
        guard let period else { return nil }
        return returns.first { $0.ownerName == company && $0.periodStart == period.start }
    }

    var body: some View {
        SheetNavigation(embedded: embedded) {
            Form {
                selection
                if let report { summary(report) }
                if let report {
                    group("Documents", report.domestic)
                    group("Foreign VAT (not in the total)", report.foreign)
                    group("To check (not in the total)", report.toCheck)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("VAT")
            .toolbar {
                if !embedded { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
            .onAppear(perform: setUp)
            .confirmationDialog("Read VAT again for all documents in this period?", isPresented: $confirmingReadAgain) {
                Button("Read Again", role: .destructive) { findVAT(overwrite: true) }
            } message: {
                Text("VAT lines you corrected by hand in this period are replaced by what Paper Trail reads from the text.")
            }
            .sheet(item: $editing) { record in
                VATEditSheet(record: record)
            }
            .sheet(item: $export) { files in
                ExportReadyView(title: String(localized: "VAT Overview Ready"), files: files.urls,
                                footer: String(localized: "The PDF has the summary followed by every invoice and receipt; the CSV lists every document and VAT line. Check deductibility with your accountant.")) { export = nil }
            }
            .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private var selection: some View {
        Section {
            if companies.isEmpty {
                Text("No owner files VAT returns yet. Set \"VAT return\" for your companies in Settings → Paying bills and VAT.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Company", selection: $company) {
                    ForEach(companies) { Text($0.name).tag($0.name) }
                }
                .onChange(of: company) { _, _ in resetPeriod() }
                if let period {
                    HStack {
                        Button("Previous", systemImage: "chevron.left") { self.period = period.previous() }
                            .labelStyle(.iconOnly)
                        Spacer()
                        Text(period.label()).font(.headline)
                        Spacer()
                        Button("Next", systemImage: "chevron.right") { self.period = period.next() }
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func summary(_ report: VATReport) -> some View {
        Section {
            ForEach(report.totalsPerRate, id: \.rate) { total in
                LabeledContent("\(VATEditor.rateText(total.rate)) over \(BillReminderText.amount(total.base))", value: BillReminderText.amount(total.vat))
            }
            LabeledContent("VAT to reclaim", value: BillReminderText.amount(report.totalToReclaim))
                .font(.headline)
            if !report.foreign.isEmpty {
                LabeledContent("Foreign VAT", value: BillReminderText.amount(report.foreignVAT))
            }
            if records.contains(where: { $0.vatInfo == nil && !($0.extractedText ?? "").isEmpty }) {
                Button("Find VAT in Documents", systemImage: "text.magnifyingglass") { findVAT(overwrite: false) }
            }
            if records.contains(where: { !($0.extractedText ?? "").isEmpty }) {
                Button("Read VAT Again for This Period…", systemImage: "arrow.clockwise") { confirmingReadAgain = true }
            }
            Button("Export PDF and CSV…", systemImage: "square.and.arrow.up") { exportReport(report) }
                .disabled(report.items.isEmpty)
            if let submitted {
                LabeledContent("Submitted", value: submitted.submittedAt.formatted(date: .abbreviated, time: .omitted))
                Button("Undo Submitted", systemImage: "arrow.uturn.backward") { undoSubmitted(submitted) }
            } else {
                Button("Mark as Submitted", systemImage: "checkmark.seal") { markSubmitted(report) }
                    .disabled(report.items.isEmpty)
            }
        } header: {
            Text("Summary")
        } footer: {
            Text("By the date on each document. Paper Trail counts the VAT lines; whether VAT is deductible is for you and your accountant to decide.")
        }
    }

    @ViewBuilder
    private func group(_ title: LocalizedStringKey, _ items: [VATReportItem]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items, id: \.relativePath) { item in
                    Button {
                        editing = records.first { $0.relativePath == item.relativePath }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.sender + (item.isReimbursedExpense ? " ·  " + String(localized: "expense") : ""))
                                Text("\(item.date.formatted(date: .abbreviated, time: .omitted)) · \(item.vat.lines.map { VATEditor.rateText($0.rate) }.joined(separator: " + "))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(BillReminderText.amount(item.vat.total)).monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func setUp() {
        if company.isEmpty { company = companies.first?.name ?? "" }
        resetPeriod()
    }

    /// Starts at the last finished period: that's usually the one to file.
    private func resetPeriod() {
        guard let kind = companies.first(where: { $0.name == company })?.vatPeriod else { period = nil; return }
        period = VATPeriod.containing(.now, kind: kind).previous()
    }

    private func findVAT(overwrite: Bool) {
        for record in records where overwrite || record.vatInfo == nil {
            guard let text = record.extractedText, !text.isEmpty else { continue }
            let found = VATExtractor.extract(from: text, total: record.amount)
            if !found.isEmpty || overwrite { record.vatInfo = found.isEmpty ? nil : found }
        }
        save()
    }

    private func exportReport(_ report: VATReport) {
        Task {
            do {
                let root = try await ICloudArchiveLocation().resolveRoot().url
                var documents: [Data] = []
                var missing: [String] = []
                for item in report.documentsInOrder {
                    do { documents.append(try InboxCollector.coordinatedRead(root.appending(path: item.relativePath))) } catch { missing.append(item.relativePath) }
                }
                guard missing.isEmpty else {
                    errorMessage = String(localized: "These documents are not in Paper Trail anymore (moved or renamed?): \(missing.joined(separator: ", ")). Put them back and export again.")
                    return
                }
                try writeExport(report, documents: documents)
            } catch {
                errorMessage = String(localized: "Could not make the export: \(error.localizedDescription)")
            }
        }
    }

    private func writeExport(_ report: VATReport, documents: [Data]) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "VAT/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = FileNamer.sanitizeComponent("VAT \(company) \(report.period.label())")
        let pdf = folder.appending(path: "\(base).pdf")
        let csv = folder.appending(path: "\(base).csv")
        try report.pdf(documents: documents).write(to: pdf, options: .atomic)
        try report.csv().write(to: csv, options: .atomic)
        export = ExportFiles(urls: [pdf, csv])
    }

    private func markSubmitted(_ report: VATReport) {
        modelContext.insert(VATReturnRecord(ownerName: company, period: report.period, vatTotal: report.totalToReclaim, documentCount: report.domestic.count))
        save()
    }

    private func undoSubmitted(_ record: VATReturnRecord) {
        modelContext.delete(record)
        save()
    }

    private func save() {
        do { try modelContext.save() } catch { errorMessage = error.localizedDescription }
    }
}

/// Edit one document's VAT lines from the overview.
struct VATEditSheet: View {
    let record: DocumentRecord
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var vat = VATInfo()
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Document", value: record.relativePath)
                    if let amount = record.amount { LabeledContent("Total", value: BillReminderText.amount(amount)) }
                }
                Section("VAT") { VATEditor(vat: $vat) }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            .keyboardDismissal()
            .navigationTitle(record.sender)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        record.vatInfo = vat.isEmpty ? nil : vat
                        do { try modelContext.save(); dismiss() } catch { errorMessage = error.localizedDescription }
                    }
                }
            }
            .onAppear { vat = record.vatInfo ?? VATInfo() }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
    }
}

struct ExportFiles: Identifiable {
    let id = UUID()
    var urls: [URL]
}

/// Share (and on the Mac, email) a set of exported files.
struct ExportReadyView: View {
    let title: String
    let files: [URL]
    let footer: String
    var done: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(files, id: \.self) { Label($0.lastPathComponent, systemImage: $0.pathExtension == "csv" ? "tablecells" : "doc.richtext") }
                } footer: { Text(footer) }
                Section {
                    ShareLink("Share…", items: files)
                    #if os(macOS)
                    Button("Email…", systemImage: "envelope") {
                        NSSharingService(named: .composeEmail)?.perform(withItems: files)
                    }
                    #endif
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) } }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 320)
        #endif
    }
}
