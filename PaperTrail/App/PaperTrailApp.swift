import PaperTrailKit
import SwiftData
import SwiftUI

@main
struct PaperTrailApp: App {
    @State private var settingsStore = SettingsStore()
    private let modelContainer = Self.makeModelContainer()
    private let filingService: FilingService
    @State private var model: AppModel
    #if os(macOS)
    @State private var mailIntake: MailIntakeService
    #endif

    init() {
        let filingService = FilingService(location: ICloudArchiveLocation(), store: CoordinatedFileStore())
        self.filingService = filingService
        _model = State(initialValue: AppModel(
            filingService: filingService,
            billService: BillService(reminders: EventKitBillReminders()),
            expenseService: ExpenseService(location: ICloudArchiveLocation())
        ))
        #if os(macOS)
        // The mailbox is checked on the Mac, independent of any open window.
        let mail = MailIntakeService(filingService: filingService)
        _mailIntake = State(initialValue: mail)
        mail.start()
        #endif
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(settingsStore)
                .environment(model)
                #if os(macOS)
                .environment(mailIntake)
                .frame(minWidth: 820, minHeight: 560)
                #endif
        }
        .modelContainer(modelContainer)
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        #endif
        .commands {
            // View → Show/Hide Sidebar (⌃⌘S).
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("Add Document…") { model.showingImporter = true }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .textEditing) {
                Button("Find Documents") { model.wantsSearchFocus = true }
                    .keyboardShortcut("f")
            }
        }

        #if os(macOS)
        // Paper Trail → Settings… (⌘,), the standard place on the Mac.
        Settings {
            NavigationStack { SettingsView(embedded: true) }
                .environment(settingsStore)
                .environment(model)
                .environment(mailIntake)
                .modelContainer(modelContainer)
                .frame(minWidth: 520, minHeight: 600)
        }
        #endif

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
