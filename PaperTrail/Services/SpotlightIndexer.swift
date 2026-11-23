import CoreSpotlight
import PaperTrailKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Keeps this device's Spotlight index in step with the filed documents. The index stays on
/// the device; it holds sender, description, amounts and the recognised text, so documents can
/// be found from the system search. Turned off in Settings, everything is removed again.
enum SpotlightIndexer {
    /// Device setting (not synced: every device has its own Spotlight index).
    static let enabledKey = "spotlightEnabled"
    /// IDs indexed last time, to remove documents that are gone.
    private static let indexedKey = "spotlightIndexedIDs"
    private static let domain = "documents"

    static func sync(_ records: [DocumentRecord], enabled: Bool) async {
        let index = CSSearchableIndex.default()
        let previous = Set(UserDefaults.standard.stringArray(forKey: indexedKey) ?? [])
        do {
            guard enabled else {
                if !previous.isEmpty || UserDefaults.standard.object(forKey: indexedKey) == nil {
                    try await index.deleteSearchableItems(withDomainIdentifiers: [domain])
                }
                UserDefaults.standard.set([String](), forKey: indexedKey)
                return
            }
            let items = records.map(item(for:))
            let current = Set(items.map(\.uniqueIdentifier))
            if !items.isEmpty { try await index.indexSearchableItems(items) }
            let removed = previous.subtracting(current)
            if !removed.isEmpty { try await index.deleteSearchableItems(withIdentifiers: Array(removed)) }
            UserDefaults.standard.set(Array(current), forKey: indexedKey)
        } catch {
            // Spotlight is a convenience; the archive and its own search keep working.
            #if DEBUG
            print("Spotlight indexing failed: \(error.localizedDescription)")
            #endif
        }
    }

    private static func item(for record: DocumentRecord) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .pdf)
        attributes.title = SpotlightText.title(sender: record.sender, description: record.documentDescription)
        attributes.displayName = attributes.title
        attributes.contentDescription = SpotlightText.summary(received: record.receivedDate, owner: record.ownerName,
                                                             category: record.categoryName, amount: record.amount)
        attributes.textContent = record.extractedText
        attributes.keywords = SpotlightText.keywords(sender: record.sender, owner: record.ownerName,
                                                     category: record.categoryName, reference: record.paymentReference)
        attributes.contentCreationDate = record.documentDate ?? record.receivedDate
        attributes.addedDate = record.filedAt
        let item = CSSearchableItem(uniqueIdentifier: record.id.uuidString, domainIdentifier: domain, attributeSet: attributes)
        item.expirationDate = .distantFuture
        return item
    }

    /// The document a Spotlight result stands for.
    static func documentID(from activity: NSUserActivity) -> UUID? {
        (activity.userInfo?[CSSearchableItemActivityIdentifier] as? String).flatMap(UUID.init(uuidString:))
    }
}

/// Re-indexes shortly after documents change (filed, edited, synced from another device).
struct SpotlightSync: ViewModifier {
    @Query private var records: [DocumentRecord]
    @AppStorage(SpotlightIndexer.enabledKey) private var enabled = true

    /// Changes in anything Spotlight shows.
    private var signature: Int {
        var hasher = Hasher()
        hasher.combine(enabled)
        for record in records {
            hasher.combine(record.id)
            hasher.combine(record.sender)
            hasher.combine(record.documentDescription)
            hasher.combine(record.ownerName)
            hasher.combine(record.categoryName)
            hasher.combine(record.amount)
            hasher.combine(record.receivedDate)
            hasher.combine(record.extractedText?.count)
        }
        return hasher.finalize()
    }

    func body(content: Content) -> some View {
        content.task(id: signature) {
            // Wait for a burst of changes (e.g. a sync) to settle; a newer change cancels this.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await SpotlightIndexer.sync(records, enabled: enabled)
        }
    }
}
