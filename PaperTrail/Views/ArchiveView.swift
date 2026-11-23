import PaperTrailKit
import SwiftData
import SwiftUI

/// All filed documents (or one owner's), newest first, searchable.
struct ArchiveView: View {
    let owner: String?

    @Environment(AppModel.self) private var model
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DocumentRecord.receivedDate, order: .reverse) private var records: [DocumentRecord]
    @State private var search = ""

    private var shown: [DocumentRecord] {
        let mine = owner.map { name in records.filter { $0.ownerName == name } } ?? records
        let terms = search.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return mine }
        return mine.filter { record in
            let haystack = [record.sender, record.documentDescription, record.categoryName, record.ownerName, record.extractedText ?? ""]
                .joined(separator: " ").lowercased()
            return terms.allSatisfy(haystack.contains)
        }
    }

    var body: some View {
        List {
            if shown.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView("No documents yet", systemImage: "archivebox",
                                           description: Text("Documents you file appear here."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
            ForEach(shown) { record in
                NavigationLink(value: DocumentRoute(id: record.id)) {
                    DocumentRow(record: record, showsOwner: owner == nil)
                }
                .contextMenu { ReimbursementMenu(record: record) }
            }
        }
        .searchable(text: $search, prompt: Text("Sender, description or text"))
        .navigationTitle(owner ?? String(localized: "Archive"))
        .toolbar { ToolbarItem(placement: .primaryAction) { AddDocumentMenu() } }
        .navigationDestination(for: DocumentRoute.self) { route in
            DocumentDetailView(id: route.id)
        }
    }
}

/// Documents waiting in Needs Review.
struct ReviewListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.reviewItems.isEmpty {
                ContentUnavailableView("All caught up", systemImage: "checkmark.circle",
                                       description: Text("Shared, emailed and Inbox documents wait here until you file them."))
            }
            ForEach(model.reviewItems) { item in
                Button { Task { await model.openReviewItem(item) } } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            if let date = item.savedDate {
                                Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: item.isDownloaded ? "doc.badge.clock" : "icloud.and.arrow.down")
                    }
                }
                .disabled(model.isPreparing)
            }
        }
        .navigationTitle("Needs Review")
        .refreshable { await model.refreshReviewItems() }
        .toolbar { ToolbarItem(placement: .primaryAction) { AddDocumentMenu() } }
    }
}

/// A filed document in a list.
struct DocumentRow: View {
    let record: DocumentRecord
    var showsOwner = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.sender).font(.body.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if let amount = record.amount { Text(BillReminderText.amount(amount)).monospacedDigit() }
                StatusBadge(record: record)
            }
        }
    }

    private var subtitle: String {
        let date = (record.documentDate ?? record.receivedDate).formatted(date: .abbreviated, time: .omitted)
        let place = showsOwner ? "\(record.ownerName) › \(record.categoryName)" : record.categoryName
        return "\(date) · \(place)"
    }
}

/// A small label for the document's state: to pay, paid, expense.
struct StatusBadge: View {
    let record: DocumentRecord

    var body: some View {
        if let (text, color) = status {
            Text(text)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .foregroundStyle(color)
                .background(color.opacity(0.15), in: .capsule)
        }
    }

    private var status: (LocalizedStringKey, Color)? {
        if record.isOpenBill {
            let overdue = (record.dueDate ?? .distantFuture) < Calendar.current.startOfDay(for: .now)
            return (overdue ? "Overdue" : "To pay", overdue ? .red : .orange)
        }
        switch record.claimState {
        case .open: return ("To claim", .teal)
        case .submitted: return ("Claimed", .blue)
        case .reimbursed: return ("Reimbursed", .green)
        case .none: break
        }
        if record.isUnpaidBill && record.isPaid { return ("Paid", .green) }
        return nil
    }
}

/// Context menu: mark a filed document as reimbursable by a company (not after it was claimed).
struct ReimbursementMenu: View {
    let record: DocumentRecord
    @Environment(AppModel.self) private var model
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        if record.claimID == nil {
            Menu("To Be Reimbursed By", systemImage: "eurosign.arrow.circlepath") {
                Button("Nobody") { model.setReimbursedBy(nil, on: record, context: modelContext) }
                ForEach(settingsStore.settings.owners.filter { $0.name != record.ownerName }) { owner in
                    Button(owner.name) { model.setReimbursedBy(owner.name, on: record, context: modelContext) }
                }
            }
        }
    }
}
