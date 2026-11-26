import EventKit
import Foundation
import Observation
import PaperTrailKit
import SwiftData

/// Shared state and actions for every screen: what is being filed, the review queue, intake
/// checks and messages. Screens show it; this decides what happens.
@Observable @MainActor
final class AppModel {
    let filingService: FilingService
    let billService: BillService
    let indexBackup = IndexBackup(location: ICloudArchiveLocation())
    let expenseService: ExpenseService

    /// The document in the filing screen, if any.
    var pending: PendingDocument?
    var showingScanner = false
    var showingImporter = false
    var isPreparing = false
    var errorMessage: String?
    var archiveRoot: ArchiveRoot?
    var reviewItems: [ReviewItem] = []
    var unreadableInboxFiles: [String] = []
    /// A bill to open from a reminder's link.
    var billToOpen: UUID?
    /// Document opened from a Spotlight result.
    var documentToOpen: DocumentRoute?
    var showingBillFromLink = false
    /// Set by Find (⌘F); the archive puts the cursor in its search field and clears it.
    var wantsSearchFocus = false
    /// Inbox problems already shown, so the check every minute doesn't repeat them.
    private var shownInboxFailures: Set<String> = []

    init(filingService: FilingService, billService: BillService, expenseService: ExpenseService) {
        self.filingService = filingService
        self.billService = billService
        self.expenseService = expenseService
    }

    func resolveArchive() async {
        do {
            archiveRoot = try await filingService.location.resolveRoot()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Moves Inbox and shared documents to Needs Review and reads the queue.
    /// Moves a document waiting in Needs Review to the Trash. Returns false (with the error
    /// shown) when it couldn't.
    @discardableResult
    func deleteReviewItem(at url: URL) async -> Bool {
        guard let root = archiveRoot?.url else { return false }
        do {
            try await filingService.reviewQueue.delete(url, root: root)
            await refreshReviewItems()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func refreshReviewItems() async {
        guard let root = archiveRoot?.url else { return }
        let report = await filingService.inboxCollector.collect(root: root)
        unreadableInboxFiles = report.unsupported
        let newFailures = report.failures.filter { !shownInboxFailures.contains($0) }
        if !newFailures.isEmpty {
            shownInboxFailures.formUnion(newFailures)
            errorMessage = newFailures.joined(separator: "\n\n")
        }
        do {
            reviewItems = try await filingService.reviewQueue.items(root: root)
        } catch {
            errorMessage = String(localized: "Could not read the Needs Review folder: \(error.localizedDescription). Pull down to try again.")
        }
    }

    func openReviewItem(_ item: ReviewItem) async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            pending = try await filingService.reviewQueue.open(item)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// One dropped file opens the filing screen; several go to Needs Review to file one by one.
    func handleDrop(_ urls: [URL]) async {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty, !isPreparing, pending == nil else { return }
        isPreparing = true
        defer { isPreparing = false }
        if fileURLs.count == 1 {
            do {
                pending = try await DocumentCapture.fromFile(at: fileURLs[0])
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        var failures: [String] = []
        for url in fileURLs {
            do {
                try await filingService.saveForReview(try await DocumentCapture.fromFile(at: url))
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        await refreshReviewItems()
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n\n") }
    }

    func handleScan(_ result: Result<[CGImage], Error>?) {
        switch result {
        case nil:
            return
        case .failure(let error):
            errorMessage = String(localized: "Scanning failed: \(error.localizedDescription). Try again.")
        case .success(let pages):
            do {
                pending = try DocumentCapture.fromScan(pages)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func importFile(_ url: URL) async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            pending = try await DocumentCapture.fromFile(at: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Marks bills paid whose reminder was completed, here or on another device.
    func syncBills(context: ModelContext) async {
        do {
            let open = try context.fetch(FetchDescriptor<DocumentRecord>(predicate: #Predicate { $0.isUnpaidBill && !$0.isPaid }))
            try await billService.syncPaidState(bills: open, context: context)
        } catch {
            errorMessage = String(localized: "Could not check Reminders for paid bills: \(error.localizedDescription)")
        }
    }

    func setReimbursedBy(_ company: String?, on record: DocumentRecord, context: ModelContext) {
        record.reimbursedBy = company
        do {
            try context.save()
        } catch {
            errorMessage = String(localized: "Could not save the change: \(error.localizedDescription)")
        }
    }

    /// papertrail://bill/<id>, the link in a bill's reminder.
    /// Links from reminders (papertrail://bill/<id>) and widgets (topay, review, bill).
    func handle(url: URL) {
        guard url.scheme == "papertrail" else { return }
        switch url.host() {
        case "bill":
            guard let id = UUID(uuidString: url.lastPathComponent) else { return }
            billToOpen = id
            showingBillFromLink = true
        case "topay":
            billToOpen = nil
            showingBillFromLink = true
        case "review":
            Task {
                await refreshReviewItems()
                if let first = reviewItems.first, pending == nil { await openReviewItem(first) }
            }
        default:
            break
        }
    }

    /// The file of a filed document in the archive.
    func fileURL(for record: DocumentRecord) -> URL? {
        archiveRoot?.url.appending(path: record.relativePath)
    }
}
