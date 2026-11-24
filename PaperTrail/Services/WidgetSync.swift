import PaperTrailKit
import SwiftData
import SwiftUI
import WidgetKit

/// Keeps the widgets' summary in the App Group up to date and asks WidgetKit to redraw.
/// With the app lock on, only counts are written (no amounts or senders).
struct WidgetSync: ViewModifier {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<DocumentRecord> { ($0.isUnpaidBill && !$0.isPaid) || $0.reimbursedBy != nil })
    private var records: [DocumentRecord]
    @AppStorage(AppLock.enabledKey) private var lockEnabled = false

    private var openBills: [DocumentRecord] { records.filter(\.isOpenBill) }
    private var openExpenses: [DocumentRecord] { records.filter { $0.claimState == .open } }

    /// Changes in anything the widgets show.
    private var signature: Int {
        var hasher = Hasher()
        hasher.combine(lockEnabled)
        hasher.combine(model.reviewItems.count)
        for record in records {
            hasher.combine(record.id)
            hasher.combine(record.sender)
            hasher.combine(record.ownerName)
            hasher.combine(record.amount)
            hasher.combine(record.dueDate)
            hasher.combine(record.isOpenBill)
            hasher.combine(record.claimState.rawValue)
        }
        return hasher.finalize()
    }

    func body(content: Content) -> some View {
        content.task(id: signature) {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            write()
        }
    }

    private func write() {
        guard let container = Self.groupContainer else { return }
        let snapshot = WidgetSnapshot.make(
            openBills: openBills.map { .init(id: $0.id, sender: $0.sender, owner: $0.ownerName, amount: $0.amount, dueDate: $0.dueDate) },
            expenseAmounts: openExpenses.map(\.amount),
            reviewCount: model.reviewItems.count,
            hidesDetails: lockEnabled
        )
        // Nothing changed for the widgets (e.g. only the time): no redraw needed.
        if let previous = WidgetSnapshot.read(from: container), Self.sameContent(previous, snapshot) { return }
        do {
            try snapshot.write(to: container)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            #if DEBUG
            print("Widget snapshot not written: \(error.localizedDescription)")
            #endif
        }
    }

    private static func sameContent(_ a: WidgetSnapshot, _ b: WidgetSnapshot) -> Bool {
        var a = a, b = b
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        return a == b
    }

    static var groupContainer: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: SharedIncoming.appGroupInfoKey) as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }
}
