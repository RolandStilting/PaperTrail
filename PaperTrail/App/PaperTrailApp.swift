import PaperTrailKit
import SwiftData
import SwiftUI

@main
struct PaperTrailApp: App {
    @State private var settingsStore = SettingsStore()
    private let modelContainer = Self.makeModelContainer()
    private let filingService: FilingService
    private let billService = BillService(reminders: EventKitBillReminders())
    private let expenseService = ExpenseService(location: ICloudArchiveLocation())
    #if os(macOS)
    @State private var mailIntake: MailIntakeService
    #endif

    init() {
        let filingService = FilingService(location: ICloudArchiveLocation(), store: CoordinatedFileStore())
        self.filingService = filingService
        #if os(macOS)
        // The mailbox is checked on the Mac, independent of any open window.
        let mail = MailIntakeService(filingService: filingService)
        _mailIntake = State(initialValue: mail)
        mail.start()
        #endif
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(filingService: filingService, billService: billService, expenseService: expenseService)
                .environment(settingsStore)
                #if os(macOS)
                .environment(mailIntake)
                #endif
        }
        .modelContainer(modelContainer)

        #if os(macOS)
        MenuBarExtra("Paper Trail", systemImage: "tray.and.arrow.down") {
            MailMenu(mail: mailIntake)
        }
        #endif
    }

    /// Uses CloudKit sync when the app has the CloudKit entitlement, and a local store otherwise.
    /// The index can always be rebuilt from the files, so falling back to local is safe.
    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema(PaperTrailSchema.models)
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
