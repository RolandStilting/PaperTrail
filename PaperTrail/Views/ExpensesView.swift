import PaperTrailKit
import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Personal expenses that companies pay back: open expenses, submitted claims and history.
struct ExpensesView: View {
    let expenseService: ExpenseService
    /// Inside the app's navigation (tab or sidebar) instead of a sheet.
    var embedded = false

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settingsStore
    @Query(filter: #Predicate<DocumentRecord> { $0.reimbursedBy != nil }) private var expenses: [DocumentRecord]
    @Query(sort: \ExpenseClaimRecord.createdAt, order: .reverse) private var claims: [ExpenseClaimRecord]

    @State private var deselected: Set<UUID> = []
    @State private var package: ClaimPackage?
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var confirmingReimbursed: ExpenseClaimRecord?

    private var companies: [String] {
        let used = Set(expenses.compactMap(\.reimbursedBy)).union(claims.map(\.ownerName))
        let configured = settingsStore.settings.owners.map(\.name)
        return configured.filter(used.contains) + used.subtracting(configured).sorted()
    }

    private func open(for company: String) -> [DocumentRecord] {
        ExpenseService.sorted(expenses.filter { $0.reimbursedBy == company && $0.claimState == .open })
    }

    var body: some View {
        SheetNavigation(embedded: embedded) {
            List {
                if companies.isEmpty {
                    ContentUnavailableView("No expenses", systemImage: "eurosign.arrow.circlepath",
                                           description: Text("Mark a document \"To be reimbursed by\" a company when filing it, or from the document list."))
                }
                ForEach(companies, id: \.self) { company in
                    companySection(company)
                }
            }
            .navigationTitle("Expenses")
            .toolbar {
                if !embedded { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
            .sheet(item: $package) { package in
                ClaimReadyView(package: package) { self.package = nil }
            }
            .confirmationDialog("Mark this claim as reimbursed?", isPresented: Binding(get: { confirmingReimbursed != nil }, set: { if !$0 { confirmingReimbursed = nil } }),
                                presenting: confirmingReimbursed) { claim in
                Button("Mark Reimbursed") { run { try expenseService.markReimbursed(claim, expenses: expenses, context: modelContext) } }
            } message: { claim in
                Text("All \(claim.expenseCount) expenses in it are cleared at once.")
            }
            .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func companySection(_ company: String) -> some View {
        let openExpenses = open(for: company)
        let selected = openExpenses.filter { !deselected.contains($0.id) }
        Section {
            ForEach(openExpenses) { expense in
                Button {
                    if deselected.contains(expense.id) { deselected.remove(expense.id) } else { deselected.insert(expense.id) }
                } label: {
                    HStack {
                        Image(systemName: deselected.contains(expense.id) ? "circle" : "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(expense.sender)
                            Text((expense.documentDate ?? expense.receivedDate).formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(expense.amount.map { BillReminderText.amount($0) } ?? String(localized: "amount missing"))
                            .foregroundStyle(expense.amount == nil ? .red : .primary)
                            .monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
            }
            if !openExpenses.isEmpty {
                Button("Create Claim (\(selected.count), \(BillReminderText.amount(ExpenseClaim.total(selected.map(ExpenseService.line)))))", systemImage: "doc.badge.plus") {
                    Task { await createClaim(company: company, expenses: selected) }
                }
                .disabled(selected.isEmpty || isWorking)
            }
            ForEach(claims.filter { $0.ownerName == company && $0.reimbursedAt == nil }) { claim in
                claimRow(claim, open: true)
            }
            let done = claims.filter { $0.ownerName == company && $0.reimbursedAt != nil }
            if !done.isEmpty {
                DisclosureGroup("Reimbursed claims (\(done.count))") {
                    ForEach(done) { claimRow($0, open: false) }
                }
            }
        } header: {
            Text(company)
        }
    }

    private func claimRow(_ claim: ExpenseClaimRecord, open: Bool) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Claim of \(claim.createdAt.formatted(date: .abbreviated, time: .omitted))")
                Text(open ? String(localized: "\(claim.expenseCount) expenses · submitted") : String(localized: "\(claim.expenseCount) expenses · reimbursed \(claim.reimbursedAt?.formatted(date: .abbreviated, time: .omitted) ?? "")"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(BillReminderText.amount(claim.total)).monospacedDigit()
            Menu {
                Button("Share Again", systemImage: "square.and.arrow.up") { Task { await shareAgain(claim) } }
                if open {
                    Button("Mark Reimbursed", systemImage: "checkmark.circle") { confirmingReimbursed = claim }
                    Button("Undo Claim", systemImage: "arrow.uturn.backward", role: .destructive) {
                        run { try expenseService.undo(claim, expenses: expenses, context: modelContext) }
                    }
                } else {
                    Button("Mark as Not Reimbursed", systemImage: "arrow.uturn.backward") {
                        run { try expenseService.markNotReimbursed(claim, expenses: expenses, context: modelContext) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func createClaim(company: String, expenses selected: [DocumentRecord]) async {
        isWorking = true
        defer { isWorking = false }
        do {
            package = try await expenseService.createClaim(company: company, expenses: selected, context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func shareAgain(_ claim: ExpenseClaimRecord) async {
        do {
            package = try await expenseService.files(for: claim, expenses: expenses.filter { $0.claimID == claim.id })
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}

/// Shows the claim's files with share and (on the Mac) email buttons.
struct ClaimReadyView: View {
    let package: ClaimPackage
    var done: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(package.pdf.lastPathComponent, systemImage: "doc.richtext")
                    Label(package.csv.lastPathComponent, systemImage: "tablecells")
                } footer: {
                    Text("The PDF has a summary page and all receipts; the CSV opens in Excel or Numbers. The expenses are now marked as submitted.")
                }
                Section {
                    ShareLink("Share…", items: [package.pdf, package.csv])
                    #if os(macOS)
                    Button("Email…", systemImage: "envelope") {
                        NSSharingService(named: .composeEmail)?.perform(withItems: [package.pdf, package.csv])
                    }
                    #endif
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Claim Ready")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 320)
        #endif
    }
}
