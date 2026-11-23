import PaperTrailKit
import SwiftData
import SwiftUI

@main
struct PaperTrailApp: App {
    @State private var settingsStore = SettingsStore()
    private let modelContainer = Self.makeModelContainer()
    private let filingService = FilingService(location: ICloudArchiveLocation(), store: CoordinatedFileStore())
    private let billService = BillService(reminders: EventKitBillReminders())

    var body: some Scene {
        WindowGroup {
            ContentView(filingService: filingService, billService: billService)
                .environment(settingsStore)
        }
        .modelContainer(modelContainer)
    }

    /// Uses CloudKit sync when the app has the CloudKit entitlement, and a local store otherwise.
    /// The index can always be rebuilt from the files, so falling back to local is safe.
    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([DocumentRecord.self, FilingRuleRecord.self])
        do {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .automatic))
        } catch {
            do {
                return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .none))
            } catch {
                fatalError("Could not open the document index: \(error.localizedDescription)")
            }
        }
    }
}
